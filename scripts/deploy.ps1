#requires -Version 7.2
<#
.SYNOPSIS
Deploys a private-backend gateway for an existing Foundry account.
.DESCRIPTION
Requires Azure CLI, Bicep CLI 0.38+, and az login. Saves private resumable state
under .azure\deploy. Never changes Foundry public access or rotates saved keys.
Pending approval and missing HTTPS/model settings return ReadyForCopilot = false.
.EXAMPLE
.\scripts\deploy.ps1 -FoundryResourceId /subscriptions/<id>/resourceGroups/<rg>/providers/Microsoft.CognitiveServices/accounts/<account>
.EXAMPLE
.\scripts\deploy.ps1 -SubscriptionId <id> -ResourceGroup gateway-rg -ParameterFile infra\my.bicepparam -Preview
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [string]$FoundryResourceId,
    [string]$ParameterFile,
    [string]$SubscriptionId,
    [string]$ResourceGroup,
    [string]$Location,
    [string]$ApimName,
    [string]$PublisherEmail,
    [string[]]$Organizations,
    [ValidateSet('Developer', 'Premium')]
    [string]$ApimSkuName,
    [switch]$ManualApproval,
    [switch]$GenerateKeys,
    [string]$Hostname,
    [string]$PfxPath,
    [securestring]$PfxPassword,
    [string]$Model,
    [switch]$VerifyOnly,
    [switch]$Preview,
    [switch]$NonInteractive,
    [switch]$AllowPublicMigration
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$root = Split-Path -Parent $PSScriptRoot
$secrets = [System.Collections.Generic.List[string]]::new()
$temporaryFiles = [System.Collections.Generic.List[string]]::new()

function Protect-Text {
    param([string]$Text)
    foreach ($secret in $secrets) {
        if (-not [string]::IsNullOrEmpty($secret)) { $Text = $Text.Replace($secret, '[REDACTED]') }
    }
    $Text
}

function Invoke-Az {
    param([string]$Operation, [string[]]$Arguments)
    $progressJob = $null
    $progressComplete = $null
    try {
        if (-not $NonInteractive -and $ProgressPreference -notin @('SilentlyContinue', 'Ignore')) {
            $progressComplete = [Threading.ManualResetEventSlim]::new($false)
            $progressJob = Start-ThreadJob -StreamingHost $Host -ArgumentList $Operation, $progressComplete -ScriptBlock {
                param([string]$Operation, [Threading.ManualResetEventSlim]$Completed)
                $frames = @('|', '/', '-', '\')
                $elapsed = [Diagnostics.Stopwatch]::StartNew()
                $frame = 0
                while (-not $Completed.IsSet) {
                    Write-Progress -Id 1 -Activity $Operation -ErrorAction Stop `
                        -Status "$($frames[$frame % $frames.Count]) Running - $($elapsed.Elapsed.ToString('hh\:mm\:ss')) elapsed"
                    $frame++
                    $null = $Completed.Wait(200)
                }
            }
        }
        $output = & az @Arguments --only-show-errors --output json 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Azure CLI failed during $Operation (exit $LASTEXITCODE). $(Protect-Text ($output -join [Environment]::NewLine))"
        }
        if ($output) { ($output -join [Environment]::NewLine) | ConvertFrom-Json -AsHashtable }
    } finally {
        if ($null -ne $progressComplete) {
            $progressComplete.Set()
            try {
                if ($null -ne $progressJob) {
                    $null = Wait-Job -Job $progressJob
                    if ($progressJob.State -eq 'Failed') {
                        Write-Warning "Running indicator failed for ${Operation}: $(Protect-Text ($progressJob.Error -join [Environment]::NewLine))"
                    }
                }
            } finally {
                if ($null -ne $progressJob) { Remove-Job -Job $progressJob -Force }
                $progressComplete.Dispose()
                Write-Progress -Id 1 -Activity $Operation -Completed
            }
        }
    }
}

function Read-Setting {
    param([string]$Value, [string]$Prompt)
    if (-not [string]::IsNullOrWhiteSpace($Value)) { return $Value }
    if ($NonInteractive -or $Preview -or $WhatIfPreference) { throw "Supply $Prompt explicitly for noninteractive/preview operation." }
    $value = Read-Host $Prompt
    if ([string]::IsNullOrWhiteSpace($value)) { throw "$Prompt is required." }
    $value
}

function Read-Confirmation {
    param([string]$Prompt, [string]$Expected)
    while ($true) {
        $answer = Read-Host "$Prompt (Enter or CANCEL to cancel)"
        if ([string]::IsNullOrWhiteSpace($answer)) { return $false }
        $answer = $answer.Trim()
        if ($answer -ieq $Expected) { return $true }
        if ($answer -ieq 'CANCEL') { return $false }
        Write-Warning "Confirmation not recognized. Type $Expected to continue, or press Enter or type CANCEL to cancel."
    }
}

function Add-SecretValues {
    param($Value)
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($item in $Value.Values) { Add-SecretValues $item }
    } elseif ($Value -is [string]) {
        if ($Value) { $secrets.Add($Value) }
    } else {
        foreach ($item in @($Value)) { if ($null -ne $item) { Add-SecretValues ([string]$item) } }
    }
}

. (Join-Path $PSScriptRoot 'private-state.ps1')

function Get-Connections {
    param($Endpoint)
    @($Endpoint.properties['privateLinkServiceConnections']) + @($Endpoint.properties['manualPrivateLinkServiceConnections']) |
        Where-Object { $null -ne $_ }
}

function Assert-Approved {
    param([object[]]$Endpoints)
    $pending = $false
    foreach ($endpoint in $Endpoints) {
        $resource = Invoke-Az 'reading private endpoint approval' @('resource', 'show', '--ids', $endpoint.id)
        $connections = @(Get-Connections $resource)
        if ($connections.Count -ne 1 -or $connections[0].properties.privateLinkServiceId -ine $endpoint.accountId) {
            throw "Unexpected private endpoint target: $($endpoint.id). Refusing to continue."
        }
        $status = $connections[0].properties.privateLinkServiceConnectionState.status
        if ($status -eq 'Pending') {
            $pending = $true
            Write-Warning "Awaiting Foundry owner approval: $($endpoint.id) -> $($endpoint.accountId). In Foundry Networking > Private endpoint connections, approve this endpoint, then rerun the same command."
        } elseif ($status -ne 'Approved' -or $resource.properties.provisioningState -ne 'Succeeded') {
            throw "Private endpoint $($endpoint.id) is $status (provisioning: $($resource.properties.provisioningState)). Resolve with its owner; no public fallback will be used."
        }
    }
    -not $pending
}

function New-ParametersFile {
    param([System.Collections.IDictionary]$Values)
    $path = Join-Path $stateDirectory ("parameters-$([guid]::NewGuid()).json")
    $parameters = @{}
    foreach ($key in $Values.Keys) { $parameters[$key] = @{ value = $Values[$key] } }
    $temporaryFiles.Add($path)
    Write-PrivateJson $path @{ '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'; contentVersion = '1.0.0.0'; parameters = $parameters }
    $path
}

function Deploy-Template {
    param([string]$Name, [string]$Template, [System.Collections.IDictionary]$Values)
    $file = New-ParametersFile $Values
    $arguments = @('--subscription', $SubscriptionId, '--resource-group', $ResourceGroup, '--name', $Name,
        '--template-file', (Join-Path $root $Template), '--parameters', "@$file")
    $null = Invoke-Az "validating $Name (check RBAC, Azure Policy and resource scope on failure)" (@('deployment', 'group', 'validate') + $arguments)
    $changes = Invoke-Az "previewing $Name" (@('deployment', 'group', 'what-if', '--no-pretty-print', '--result-format', 'ResourceIdOnly') + $arguments)
    foreach ($change in @($changes.changes)) {
        Write-Host "$($change.changeType): $($change.resourceId)"
        if ($change.changeType -eq 'Delete') { throw 'Preview includes a deletion. Review and apply this migration manually.' }
    }
    if (-not $NonInteractive -and -not (Read-Confirmation "Type APPLY to apply the displayed $Name changes" 'APPLY')) { throw 'Deployment cancelled after preview.' }
    Invoke-Az "deploying $Name" (@('deployment', 'group', 'create', '--mode', 'Incremental') + $arguments)
}

function Invoke-GatewayRequest {
    param([string]$Uri, [string]$Key, $Body)
    $arguments = @{ Uri = $Uri; Headers = @{ Authorization = "Bearer $Key" }; TimeoutSec = 120; MaximumRedirection = 0 }
    if ($null -ne $Body) {
        $arguments.Method = 'Post'
        $arguments.ContentType = 'application/json'
        $arguments.Body = $Body | ConvertTo-Json -Depth 10 -Compress
    }
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try { return Invoke-RestMethod @arguments }
        catch [Microsoft.PowerShell.Commands.HttpResponseException] {
            $status = [int]$_.Exception.Response.StatusCode
            if ($attempt -eq 3 -or $status -notin @(401, 403, 429, 500, 502, 503, 504)) {
                throw "Gateway verification failed (HTTP $status). Check org keys, model access, private DNS/approval and APIM's Foundry role; response bodies are not logged."
            }
            Write-Warning "Gateway returned HTTP $status; retrying verification ($attempt/3)."
            Start-Sleep -Seconds 10
        }
        catch [System.Net.Http.HttpRequestException] {
            throw 'Cannot establish trusted HTTPS to the gateway. Check public DNS, certificate hostname/chain and gateway health.'
        }
    }
}

try {
    if ($VerifyOnly) {
        foreach ($name in @('FoundryResourceId', 'ParameterFile', 'Location', 'ApimName', 'PublisherEmail',
                'Organizations', 'ApimSkuName', 'ManualApproval', 'GenerateKeys', 'PfxPath', 'PfxPassword',
                'AllowPublicMigration', 'Preview', 'WhatIf')) {
            if ($PSBoundParameters.ContainsKey($name)) { throw "VerifyOnly cannot be combined with -$name. It uses saved deployment settings." }
        }
    }
    $tools = if ($VerifyOnly) { @('az') } else { @('az', 'bicep') }
    foreach ($tool in $tools) {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "$tool is required. Install it before running this helper." }
    }
    if (-not $VerifyOnly) {
        $version = & bicep --version
        if ($LASTEXITCODE -ne 0 -or $version -notmatch 'version (\d+\.\d+\.\d+)' -or [version]$Matches[1] -lt [version]'0.38.0') {
            throw 'Bicep CLI 0.38 or later is required.'
        }
    }
    $SubscriptionId = Read-Setting $SubscriptionId 'SubscriptionId'
    $ResourceGroup = Read-Setting $ResourceGroup 'ResourceGroup'
    if ($SubscriptionId -notmatch '^[a-zA-Z0-9-]+$' -or $ResourceGroup -notmatch '^[\w.()-]+$' -or $ResourceGroup.EndsWith('.')) {
        throw 'Invalid target subscription or resource group.'
    }
    $null = Invoke-Az 'checking target subscription authentication' @('account', 'show', '--subscription', $SubscriptionId)
    $stateDirectory = Join-Path $root ".azure\deploy\$SubscriptionId\$ResourceGroup"
    $statePath = Join-Path $stateDirectory 'state.json'
    $state = if (Test-Path -LiteralPath $statePath) { Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json -AsHashtable } else { @{} }
    if ($VerifyOnly -and -not $state['parameters']) { throw 'VerifyOnly requires saved deployment state for this subscription/resource group. It will not provision missing resources.' }
    $p = if ($state['parameters']) { $state['parameters'] | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable } else { @{} }
    if ($ParameterFile) {
        $path = (Resolve-Path -LiteralPath $ParameterFile).Path
        if ([IO.Path]::GetExtension($path) -eq '.bicepparam') {
            $compiled = & bicep build-params $path --stdout 2>&1
            if ($LASTEXITCODE -ne 0) { throw 'Bicep parameter compilation failed. Fix the supplied parameter file.' }
            $document = ($compiled | Where-Object { $_ -is [string] }) -join [Environment]::NewLine | ConvertFrom-Json -AsHashtable
            if ($document.ContainsKey('parametersJson')) { $document = $document.parametersJson | ConvertFrom-Json -AsHashtable }
        } else {
            $document = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json -AsHashtable
        }
        foreach ($entry in $document.parameters.GetEnumerator()) {
            if (-not $entry.Value.ContainsKey('value')) { throw 'This helper requires resolved parameter values; use the manual Bicep path for Key Vault parameter references.' }
            $p[$entry.Key] = $entry.Value.value
        }
    }
    foreach ($key in @('orgKeys', 'appGwSharedSecret', 'appGwHttpsPfxBase64', 'appGwHttpsPfxPassword')) { Add-SecretValues $p[$key] }
    $Location = if ($Location) { $Location } elseif ($p['location']) { $p['location'] } else { $state['location'] }
    $Location = Read-Setting $Location 'Location'
    $p.location = $Location
    foreach ($pair in @(@('apimName', $ApimName), @('apimPublisherEmail', $PublisherEmail), @('apimSkuName', $ApimSkuName))) {
        if ($pair[1]) { $p[$pair[0]] = $pair[1] }
    }
    $p.apimName = Read-Setting $p['apimName'] 'ApimName'
    $p.apimPublisherEmail = Read-Setting $p['apimPublisherEmail'] 'PublisherEmail'
    if ($p.apimName -notmatch '^[a-zA-Z][a-zA-Z0-9-]{0,48}[a-zA-Z0-9]$') { throw 'ApimName must be 2-50 letters, digits or hyphens, beginning with a letter and ending with a letter/digit.' }
    if (-not $p['apimSkuName']) { $p.apimSkuName = 'Developer' }
    foreach ($key in @('deployAppGateway', 'enablePrivateNetworking')) { if (-not $p.ContainsKey($key)) { $p[$key] = $true } }
    if (-not $p.deployAppGateway -or -not $p.enablePrivateNetworking -or $p.apimSkuName -notin @('Developer', 'Premium')) {
        throw 'The guided helper requires Application Gateway, private networking, and Developer or classic Premium APIM. Use the documented manual path for explicit public/APIM-only deployments.'
    }
    if ($p['appGwAllowedClientIp']) { throw 'Clear appGwAllowedClientIp in private mode; the APIM NSG restricts access by gateway subnet.' }
    if (-not $p['appGwName']) { $p.appGwName = "$($p.apimName)-appgw" }
    if ($PSBoundParameters.ContainsKey('ManualApproval')) { $p.foundryPrivateEndpointManualApproval = [bool]$ManualApproval }
    if (-not $p.ContainsKey('foundryPrivateEndpointManualApproval')) { $p.foundryPrivateEndpointManualApproval = $false }
    if ($state['parameters']) {
        foreach ($key in @('apimName', 'appGwName', 'foundryPrivateEndpointManualApproval')) {
            if ($p[$key] -cne $state.parameters[$key]) { throw "Saved $key differs from this request. Use the manual migration path rather than changing resource identity/connection mode on resume." }
        }
    }
    if ($FoundryResourceId) {
        if ($FoundryResourceId -notmatch '^/subscriptions/([^/]+)/resourceGroups/([^/]+)/providers/Microsoft\.CognitiveServices/accounts/([^/]+)$') {
            throw 'FoundryResourceId must identify an existing Microsoft.CognitiveServices/accounts resource.'
        }
        $p.foundryAccountSubscriptionId = $Matches[1]
        $p.foundryAccountResourceGroup = $Matches[2]
        $p.foundryAccountName = $Matches[3]
    } elseif (-not $p['foundryAccountName']) {
        throw 'Supply FoundryResourceId or a parameter file containing the existing Foundry account.'
    }
    if (-not $p['foundryAccountSubscriptionId']) { $p.foundryAccountSubscriptionId = $SubscriptionId }
    if (-not $p['foundryAccountResourceGroup']) { $p.foundryAccountResourceGroup = $ResourceGroup }
    if ($state['parameters']) {
        foreach ($key in @('foundryAccountName', 'foundryAccountSubscriptionId', 'foundryAccountResourceGroup')) {
            if ($p[$key] -ine $state.parameters[$key]) { throw "Saved $key differs from this request. Use a separate target or the manual migration path." }
        }
    }
    $accounts = [System.Collections.Generic.List[object]]::new()
    $identities = [System.Collections.Generic.List[string]]::new()
    $specs = @(@{ accountName = $p.foundryAccountName; subscriptionId = $p.foundryAccountSubscriptionId; resourceGroup = $p.foundryAccountResourceGroup; backendBaseUrl = $p['foundryBackendBaseUrl'] }) + @($p['foundryBackends'])
    foreach ($spec in $specs) {
        if ($null -eq $spec) { continue }
        $account = [ordered]@{
            accountName = $spec.accountName
            subscriptionId = if ($spec['subscriptionId']) { $spec['subscriptionId'] } else { $p.foundryAccountSubscriptionId }
            resourceGroup = if ($spec['resourceGroup']) { $spec['resourceGroup'] } else { $p.foundryAccountResourceGroup }
        }
        $identity = $account | ConvertTo-Json -Compress
        if ($identities.Contains($identity)) { continue }
        $identities.Add($identity)
        $id = "/subscriptions/$($account.subscriptionId)/resourceGroups/$($account.resourceGroup)/providers/Microsoft.CognitiveServices/accounts/$($account.accountName)"
        $resource = Invoke-Az "reading Foundry account $id (ARM only)" @('resource', 'show', '--ids', $id, '--api-version', '2023-05-01')
        if ($resource.kind -notin @('OpenAI', 'AIServices')) { throw "Unsupported Foundry account kind: $($resource.kind)." }
        $endpoint = if ($spec['backendBaseUrl']) { $spec['backendBaseUrl'].TrimEnd('/') } else { "https://$($account.accountName).openai.azure.com" }
        $validHosts = @('openai.azure.com', 'cognitiveservices.azure.com', 'services.ai.azure.com') | ForEach-Object { "https://$($account.accountName).$_" }
        if ($endpoint -notin $validHosts) { throw "Unsupported private Foundry backend URL for $id. Use a standard account hostname." }
        Write-Host "Foundry: $id; kind $($resource.kind); public access $($resource.properties.publicNetworkAccess) (unchanged)."
        $accounts.Add($account)
    }
    $groupExists = Invoke-Az 'checking resource group' @('group', 'exists', '--subscription', $SubscriptionId, '--name', $ResourceGroup)
    if ($groupExists) {
        $existingApims = @(Invoke-Az 'checking existing APIM instances' @('apim', 'list', '--subscription', $SubscriptionId, '--resource-group', $ResourceGroup))
        if ($existingApims.Count -gt 0 -and $p.apimName -notin $existingApims.name) { throw 'This resource group already contains a different APIM. Supply its existing parameter file or choose a separate resource group.' }
        $existingApim = $existingApims | Where-Object { $_.name -eq $p.apimName }
        if ($existingApim -and $existingApim.virtualNetworkType -ne 'Internal' -and -not $AllowPublicMigration) {
            throw 'Existing APIM is public. Review downtime and the migration preview, then explicitly supply -AllowPublicMigration to adopt private networking.'
        }
        $vnets = @(Invoke-Az 'checking existing network' @('network', 'vnet', 'list', '--subscription', $SubscriptionId, '--resource-group', $ResourceGroup))
        $vnet = $vnets | Where-Object { $_.name -eq "$($p.appGwName)-vnet" }
        if ($vnet) {
            if (@($vnet.addressSpace.addressPrefixes).Count -ne 1 -or $vnet.addressSpace.addressPrefixes[0] -ne '10.50.0.0/16') { throw 'Existing gateway VNet address space is incompatible. Review networking manually.' }
            $prefixes = @{ 'appgw-subnet' = '10.50.0.0/24'; 'apim-subnet' = '10.50.1.0/24'; 'private-endpoints-subnet' = '10.50.2.0/24' }
            foreach ($subnet in $vnet.subnets) {
                if (-not $prefixes.ContainsKey($subnet.name) -or $subnet.addressPrefix -ne $prefixes[$subnet.name]) { throw 'Existing gateway subnet layout is incompatible. Refusing to replace attached subnets.' }
                if ($subnet.name -eq 'appgw-subnet' -and $subnet['networkSecurityGroup']) {
                    $expected = if ($p['appGwExistingNsgName']) { $p.appGwExistingNsgName } else { "$($p.appGwName)-nsg" }
                    $expectedId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Network/networkSecurityGroups/$expected"
                    if ($subnet.networkSecurityGroup.id -ine $expectedId) { throw 'Gateway has a different NSG. Set appGwExistingNsgName in your parameter file to preserve its association.' }
                }
            }
        }
        $existingEndpoints = @(Invoke-Az 'checking existing endpoint identities and modes' @('network', 'private-endpoint', 'list', '--subscription', $SubscriptionId, '--resource-group', $ResourceGroup))
        foreach ($endpoint in $existingEndpoints) {
            if ($endpoint.name -notlike "$($p.appGwName)-foundry-pe-*") { continue }
            $isManual = @($endpoint['manualPrivateLinkServiceConnections'] | Where-Object { $null -ne $_ }).Count -gt 0
            if ($isManual -ne $p.foundryPrivateEndpointManualApproval) { throw 'Existing private endpoint connection mode differs. Preserve foundryPrivateEndpointManualApproval on reruns.' }
            $connections = @(@($endpoint['privateLinkServiceConnections']) + @($endpoint['manualPrivateLinkServiceConnections']) | Where-Object { $null -ne $_ })
            $indexText = $endpoint.name.Substring("$($p.appGwName)-foundry-pe-".Length)
            $index = 0
            if (-not [int]::TryParse($indexText, [ref]$index) -or $index -lt 0 -or $index -ge $accounts.Count) { throw 'Existing private endpoint mapping differs; preserve backend account ordering or migrate manually.' }
            $account = $accounts[$index]
            $expectedAccountId = "/subscriptions/$($account.subscriptionId)/resourceGroups/$($account.resourceGroup)/providers/Microsoft.CognitiveServices/accounts/$($account.accountName)"
            if (@($connections).Count -ne 1 -or $connections[0].privateLinkServiceId -ine $expectedAccountId) { throw 'Existing private endpoint target differs. Preserve backend account ordering or migrate manually.' }
            foreach ($connection in $connections) {
                if ($connection.privateLinkServiceConnectionState.status -in @('Rejected', 'Disconnected')) { throw 'Existing private endpoint was rejected/disconnected. Resolve with its owner before redeploying.' }
            }
        }
    }
    $providers = @(@{ subscription = $SubscriptionId; namespaces = @('Microsoft.ApiManagement', 'Microsoft.Network') })
    foreach ($sub in @($accounts.subscriptionId | Select-Object -Unique)) {
        $providers += @{ subscription = $sub; namespaces = @('Microsoft.Network', 'Microsoft.CognitiveServices') }
    }
    foreach ($feature in @(@('deployObservability', 'Microsoft.OperationalInsights'), @('deployObservability', 'Microsoft.Insights'), @('deployContentSafety', 'Microsoft.CognitiveServices'), @('deploySemanticCache', 'Microsoft.Cache'))) {
        if ($p[$feature[0]]) { $providers += @{ subscription = $SubscriptionId; namespaces = @($feature[1]) } }
    }
    $registrations = [System.Collections.Generic.List[object]]::new()
    foreach ($provider in $providers) {
        foreach ($namespace in $provider.namespaces) {
            $registration = Invoke-Az "checking $namespace registration in $($provider.subscription)" @('provider', 'show', '--subscription', $provider.subscription, '--namespace', $namespace)
            if ($registration.registrationState -ne 'Registered') { $registrations.Add(@{ subscription = $provider.subscription; namespace = $namespace }) }
        }
    }
    $Hostname = if ($Hostname) { $Hostname } else { $state['hostname'] }
    if ($Hostname -and ([Uri]::CheckHostName($Hostname) -ne [UriHostNameType]::Dns -or $Hostname.Contains(':'))) { throw 'Hostname must be a DNS hostname without scheme, path or port.' }
    $Model = if ($Model) { $Model } else { $state['model'] }
    Write-Host "Target: $SubscriptionId / $ResourceGroup / $Location. APIM: $($p.apimName), $($p.apimSkuName)."
    if ($VerifyOnly) {
        Write-Host 'Verifying existing infrastructure only. No deployments, provider registrations, key generation or state writes.'
        $networkOutputs = @{ vnetId = @{ value = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Network/virtualNetworks/$($p.appGwName)-vnet" } }
        $endpoints = @(for ($i = 0; $i -lt $accounts.Count; $i++) {
            $account = $accounts[$i]
            @{
                id = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Network/privateEndpoints/$($p.appGwName)-foundry-pe-$i"
                accountId = "/subscriptions/$($account.subscriptionId)/resourceGroups/$($account.resourceGroup)/providers/Microsoft.CognitiveServices/accounts/$($account.accountName)"
            }
        })
        $gateway = Invoke-Az 'reading existing Application Gateway' @('network', 'application-gateway', 'show', '--subscription', $SubscriptionId, '--resource-group', $ResourceGroup, '--name', $p.appGwName)
        $https = @($gateway.httpListeners | Where-Object { $_.protocol -eq 'Https' }).Count -gt 0
        $publicIpIds = @($gateway.frontendIPConfigurations | Where-Object { $_['publicIPAddress'] } | ForEach-Object { $_.publicIPAddress.id })
        if ($publicIpIds.Count -ne 1) { throw 'Expected one public Application Gateway frontend for verification.' }
        $publicIp = Invoke-Az 'reading existing gateway public IP' @('network', 'public-ip', 'show', '--ids', $publicIpIds[0])
        $gatewayPublicIp = $publicIp.ipAddress
    } else {
        Write-Warning 'Charges apply for APIM, WAF_v2 Application Gateway, private endpoints and private DNS. Developer is for testing; classic Premium has production-tier charges.'
        Write-Host 'Required independently: permission to assign APIM a Foundry data-plane role, and private endpoint owner approval. Azure Policy can still block deployment.'
        if ($Preview -or -not $PSCmdlet.ShouldProcess("$SubscriptionId/$ResourceGroup", 'Prepare private networking and deploy gateway')) {
            return [pscustomobject]@{ Status = 'PreflightOnly'; ReadyForCopilot = $false; MissingProviderRegistrations = $registrations.ToArray() }
        }
        if (-not $NonInteractive -and -not (Read-Confirmation 'Type DEPLOY to confirm this target and its charges' 'DEPLOY')) { throw 'Deployment cancelled.' }
        if (-not $p['orgKeys']) { $p.orgKeys = @{} }
        if (-not $Organizations -and $p.orgKeys.Count -eq 0) { $Organizations = (Read-Setting '' 'Organizations (comma-separated slugs)') -split ',' }
        foreach ($org in @($Organizations)) {
            if ($null -eq $org) { continue }
            if ($org -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') { throw "Invalid organization slug: $org." }
            if (-not $p.orgKeys.ContainsKey($org)) { $p.orgKeys[$org] = '' }
        }
        $needsKeys = -not $p['appGwSharedSecret'] -or @($p.orgKeys.Values | Where-Object { -not $_ }).Count -gt 0
        if ($needsKeys -and -not $GenerateKeys -and -not $NonInteractive) { $GenerateKeys = (Read-Host 'Generate and save missing keys only? [y/N]') -eq 'y' }
        foreach ($org in @($p.orgKeys.Keys)) {
            if ($org -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') { throw "Invalid organization slug: $org." }
            if (-not $p.orgKeys[$org]) {
                if (-not $GenerateKeys) { throw 'Missing organization keys. Supply orgKeys in a private parameter file or explicitly use -GenerateKeys.' }
                $p.orgKeys[$org] = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).ToLowerInvariant()
            }
        }
        if (-not $p['appGwSharedSecret']) {
            if (-not $GenerateKeys) { throw 'Missing gateway secret. Supply it in a private parameter file or explicitly use -GenerateKeys.' }
            $p.appGwSharedSecret = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).ToLowerInvariant()
        }
        if ($p.appGwSharedSecret.Length -lt 32 -or $p.orgKeys.Count -eq 0) { throw 'At least one org key and a gateway secret of at least 32 characters are required.' }
        if ($PfxPath) {
            if (-not $PfxPassword) {
                if ($NonInteractive) { throw 'Supply PfxPassword with PfxPath.' }
                $PfxPassword = Read-Host 'PFX password' -AsSecureString
            }
            $p.appGwHttpsPfxBase64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $PfxPath).Path))
            $p.appGwHttpsPfxPassword = [System.Net.NetworkCredential]::new('', $PfxPassword).Password
            $p.appGwEnableHttps = $true
        }
        foreach ($key in @('orgKeys', 'appGwSharedSecret', 'appGwHttpsPfxBase64', 'appGwHttpsPfxPassword')) { Add-SecretValues $p[$key] }
        $https = if ($p.ContainsKey('appGwEnableHttps')) { $p.appGwEnableHttps } else { -not [string]::IsNullOrEmpty($p['appGwHttpsPfxBase64']) }
        if ($https -and (-not $p['appGwHttpsPfxBase64'] -or -not $p['appGwHttpsPfxPassword'])) { throw 'HTTPS requires both PFX data and password.' }
        Write-PrivateJson $statePath @{ location = $Location; hostname = $Hostname; model = $Model; parameters = $p }
        Write-Host "Resumable parameters/keys saved privately in $statePath. Keep this file private; rerun with the same target to resume."
        foreach ($registration in $registrations) {
            if ($registration.subscription -ne $SubscriptionId) {
                if ($NonInteractive -or (Read-Host "Register $($registration.namespace) in Foundry subscription $($registration.subscription)? [y/N]") -ne 'y') {
                    throw "Ask the subscription owner to register $($registration.namespace) in $($registration.subscription), then resume."
                }
            }
            $null = Invoke-Az 'registering provider' @('provider', 'register', '--subscription', $registration.subscription, '--namespace', $registration.namespace, '--wait')
        }
        if (-not $groupExists) { $null = Invoke-Az 'creating target resource group' @('group', 'create', '--subscription', $SubscriptionId, '--name', $ResourceGroup, '--location', $Location) }
        $networkParameters = @{ location = $Location; appGwName = $p.appGwName; enableHttps = $https }
        if ($p['appGwExistingNsgName']) { $networkParameters.existingNsgName = $p.appGwExistingNsgName }
        if ($p['tags']) { $networkParameters.tags = $p.tags }
        $network = Deploy-Template 'appGatewayNetwork' 'infra\modules\gateway-network.bicep' $networkParameters
        $networkOutputs = $network.properties.outputs
        $privateParameters = @{
            location = $Location; namePrefix = $p.appGwName; vnetId = $networkOutputs.vnetId.value
            subnetId = $networkOutputs.privateEndpointSubnetId.value; foundryAccounts = $accounts.ToArray()
            manualApproval = $p.foundryPrivateEndpointManualApproval
        }
        if ($p['tags']) { $privateParameters.tags = $p.tags }
        $privateNetwork = Deploy-Template 'foundryPrivateNetwork' 'infra\modules\foundry-private-network.bicep' $privateParameters
        $endpoints = @($privateNetwork.properties.outputs.endpoints.value)
        if ($endpoints.Count -ne $accounts.Count) { throw 'Private network deployment did not return every expected endpoint.' }
        if (-not (Assert-Approved $endpoints)) { return [pscustomobject]@{ Status = 'AwaitingApproval'; ReadyForCopilot = $false; StatePath = $statePath } }
        $deployment = Deploy-Template 'main' 'infra\main.bicep' $p
        if ($deployment.properties.provisioningState -ne 'Succeeded') { throw 'Main deployment did not succeed.' }
        $gatewayPublicIp = $deployment.properties.outputs.appGatewayPublicIp.value
    }
    if (-not (Assert-Approved $endpoints)) { return [pscustomobject]@{ Status = 'AwaitingApproval'; ReadyForCopilot = $false; StatePath = $statePath } }
    $apim = Invoke-Az 'verifying internal APIM' @('apim', 'show', '--subscription', $SubscriptionId, '--resource-group', $ResourceGroup, '--name', $p.apimName)
    $privateAddresses = @($apim['privateIpAddresses'] | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($apim.virtualNetworkType -ne 'Internal' -or $privateAddresses.Count -eq 0) { throw 'APIM is not provisioned with an internal private IP.' }
    foreach ($endpoint in $endpoints) {
        $name = ($endpoint.id -split '/')[-1]
        $groups = @(Invoke-Az 'verifying endpoint DNS zone group' @('network', 'private-endpoint', 'dns-zone-group', 'list', '--subscription', $SubscriptionId, '--resource-group', $ResourceGroup, '--endpoint-name', $name))
        if ($groups.Count -ne 1 -or @($groups[0].privateDnsZoneConfigs).Count -eq 0) { throw "Private DNS zone group missing for $name." }
        foreach ($zone in $groups[0].privateDnsZoneConfigs) {
            $zoneName = ($zone.privateDnsZoneId -split '/')[-1]
            $links = @(Invoke-Az 'verifying private DNS VNet link' @('network', 'private-dns', 'link', 'vnet', 'list', '--subscription', $SubscriptionId, '--resource-group', $ResourceGroup, '--zone-name', $zoneName))
            if (@($links | Where-Object { $_.virtualNetwork.id -ieq $networkOutputs.vnetId.value -and $_.virtualNetworkLinkState -eq 'Completed' }).Count -eq 0) { throw "Private DNS VNet link is not ready for $zoneName." }
        }
    }
    $healthy = $false
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $health = Invoke-Az 'checking Application Gateway backend health' @('network', 'application-gateway', 'show-backend-health', '--subscription', $SubscriptionId, '--resource-group', $ResourceGroup, '--name', $p.appGwName)
        $servers = @($health.backendAddressPools.backendHttpSettingsCollection.servers)
        if ($servers.Count -gt 0 -and @($servers | Where-Object { $_.health -ne 'Healthy' }).Count -eq 0) { $healthy = $true; break }
        if ($attempt -lt 3) { Write-Warning 'APIM backend is not healthy yet; retrying.'; Start-Sleep -Seconds 10 }
    }
    if (-not $healthy) { throw 'Application Gateway backend is unhealthy. Check APIM private VIP, NSG, Host/SNI and provisioning state.' }
    if (-not $https -or -not $Hostname) {
        Write-Warning "Infrastructure deployed, not ready for Copilot. Point a trusted hostname to $gatewayPublicIp, obtain a full-chain PFX and rerun with -Hostname, -PfxPath and -PfxPassword. Never send keys over HTTP."
        return [pscustomobject]@{ Status = 'AwaitingHttps'; ReadyForCopilot = $false; StatePath = $statePath }
    }
    $orgs = @(if ($p['orgs']) { $p.orgs } else { $p.orgKeys.Keys })
    if ($orgs.Count -eq 0) { throw 'No organizations selected for verification.' }
    foreach ($org in $orgs) {
        if (-not $p.orgKeys.ContainsKey($org)) { throw "No client key for selected organization $org." }
        $models = Invoke-GatewayRequest "https://$Hostname/byok/$org/models" $p.orgKeys[$org] $null
        if (-not $models.data -or @($models.data.id).Count -eq 0) { throw "Model discovery returned no deployments for $org." }
        if (-not $Model -and -not $NonInteractive) { $Model = Read-Host "Model deployment to verify for all selected orgs (available for ${org}: $($models.data.id -join ', '))" }
        if (-not $Model) {
            Write-Warning 'HTTPS discovery passed. Rerun with -Model <deployment-name> to verify inference before connecting Copilot.'
            return [pscustomobject]@{ Status = 'AwaitingModelVerification'; ReadyForCopilot = $false; StatePath = $statePath }
        }
        if ($Model -notin @($models.data.id)) { throw "Selected deployment is not discoverable by $org. Choose a model permitted for all selected orgs or verify separately." }
        $reply = Invoke-GatewayRequest "https://$Hostname/byok/$org/chat/completions" $p.orgKeys[$org] @{
            model = $Model; messages = @(@{ role = 'user'; content = 'Reply with OK.' }); max_completion_tokens = 128
        }
        if (-not $reply.choices -or [string]::IsNullOrWhiteSpace($reply.choices[0].message.content)) { throw "Completion verification returned no assistant text for $org." }
    }
    if (-not $VerifyOnly) { Write-PrivateJson $statePath @{ location = $Location; hostname = $Hostname; model = $Model; parameters = $p } }
    Write-Host "Ready for Copilot. Base URL: https://$Hostname/byok/<org>. Retrieve the matching org key from the private state file; keys are not printed."
    [pscustomobject]@{ Status = 'Verified'; ReadyForCopilot = $true; StatePath = $statePath }
}
finally {
    foreach ($path in $temporaryFiles) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path } }
}
