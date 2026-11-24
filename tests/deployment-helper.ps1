#requires -Version 7.2
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$scratch = Join-Path ([IO.Path]::GetTempPath()) "byok-deploy-helper-$([guid]::NewGuid())"
$helperDirectory = Join-Path $scratch 'scripts'
$null = New-Item -ItemType Directory -Path $helperDirectory
$helper = Join-Path $helperDirectory 'deploy.ps1'
Copy-Item -LiteralPath (Join-Path $root 'scripts\deploy.ps1') -Destination $helper
$parametersFile = Join-Path $scratch 'input.json'
$stateFile = Join-Path $scratch '.azure\deploy\gateway-sub\gateway-rg\state.json'
$vnetId = '/subscriptions/gateway-sub/resourceGroups/gateway-rg/providers/Microsoft.Network/virtualNetworks/test-apim-appgw-vnet'
$accountId = '/subscriptions/foundry-sub/resourceGroups/models-rg/providers/Microsoft.CognitiveServices/accounts/existing-foundry'
$endpointId = '/subscriptions/gateway-sub/resourceGroups/gateway-rg/providers/Microsoft.Network/privateEndpoints/test-apim-appgw-foundry-pe-0'
$target = @{ SubscriptionId = 'gateway-sub'; ResourceGroup = 'gateway-rg'; ParameterFile = $parametersFile; NonInteractive = $true; Confirm = $false }
$interactiveTarget = $target.Clone()
$interactiveTarget.NonInteractive = $false
$startThreadJobCommand = Get-Command Start-ThreadJob
$script:checks = 0

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ($Actual -cne $Expected) { throw "$Message Expected '$Expected', got '$Actual'." }
    $script:checks++
}

function Assert-Throws {
    param([scriptblock]$Operation, [string]$Pattern)
    try { & $Operation | Out-Null }
    catch {
        if ($_.Exception.Message -notmatch $Pattern) { throw "Unexpected error: $($_.Exception.Message)`n$($_.ScriptStackTrace)" }
        $script:checks++
        return
    }
    throw "Expected an error matching '$Pattern'."
}

function Reset-Mock {
    if (Test-Path -LiteralPath $stateFile) { Remove-Item -LiteralPath $stateFile }
    $script:values = @{
        location = 'eastus2'; apimName = 'test-apim'; apimPublisherEmail = 'admin@example.com'
        foundryAccountName = 'existing-foundry'; foundryAccountSubscriptionId = 'foundry-sub'; foundryAccountResourceGroup = 'models-rg'
        orgKeys = @{ team = 'private-org-key' }; appGwSharedSecret = 'private-gateway-secret-at-least-32-characters'
    }
    $script:mock = @{
        Calls = [System.Collections.Generic.List[object]]::new()
        Requests = [System.Collections.Generic.List[object]]::new()
        Deployments = [System.Collections.Generic.List[string]]::new()
        GroupExists = $false; Approval = 'Approved'; Manual = $false; Public = 'Disabled'
        Fail = ''; Health = 'Healthy'; EmptyModels = $false; EmptyCompletion = $false
        ExistingApims = @(); ExistingVnets = @(); ExistingEndpoints = @()
        MainParameters = $null; Unregistered = $false
        EndpointMappings = @()
        Answers = [System.Collections.Generic.Queue[string]]::new()
        Prompts = [System.Collections.Generic.List[object]]::new()
        ProgressJobs = [System.Collections.Generic.List[object]]::new()
        ProgressCompletions = [System.Collections.Generic.List[string]]::new()
        DelayCommand = ''
        Apim = @{ virtualNetworkType = 'Internal'; privateIpAddresses = @('10.50.1.4') }
    }
    Save-Input
}

function Save-Input {
    $parameters = @{}
    foreach ($entry in $script:values.GetEnumerator()) { $parameters[$entry.Key] = @{ value = $entry.Value } }
    [IO.File]::WriteAllText($parametersFile, (@{ parameters = $parameters } | ConvertTo-Json -Depth 30))
}

function bicep {
    $global:LASTEXITCODE = 0
    if ($args[0] -eq '--version') { return 'Bicep CLI version 0.38.33 (test)' }
    if ($args[0] -eq 'build-params') {
        return (@{ parametersJson = (Get-Content -Raw -LiteralPath $parametersFile) } | ConvertTo-Json -Compress)
    }
    throw 'Unexpected Bicep command.'
}

function az {
    $arguments = @($args)
    $mock.Calls.Add($arguments)
    $global:LASTEXITCODE = 0
    $command = $arguments -join ' '
    if ($mock.DelayCommand -and $command.Contains($mock.DelayCommand)) {
        [Threading.Thread]::Sleep(1200)
    }
    if ($mock.Fail -and $command.Contains($mock.Fail)) {
        $global:LASTEXITCODE = 9
        return 'AuthorizationFailed for private-org-key; private-gateway-secret-at-least-32-characters'
    }
    $result = switch -Regex ($command) {
        '^account show ' { @{ id = 'gateway-sub' }; break }
        '^resource show ' {
            if ($command.Contains('Microsoft.CognitiveServices/accounts')) {
                @{ id = $accountId; kind = 'AIServices'; properties = @{ publicNetworkAccess = $mock.Public } }
            } else {
                $id = $arguments[([array]::IndexOf($arguments, '--ids') + 1)]
                $mapping = $mock.EndpointMappings | Where-Object { $_.id -eq $id }
                $connection = @{ properties = @{ privateLinkServiceId = $mapping.accountId; privateLinkServiceConnectionState = @{ status = $mock.Approval } } }
                @{ properties = @{
                    provisioningState = 'Succeeded'
                    privateLinkServiceConnections = if ($mock.Manual) { @() } else { @($connection) }
                    manualPrivateLinkServiceConnections = if ($mock.Manual) { @($connection) } else { @() }
                } }
            }
            break
        }
        '^group exists ' { $mock.GroupExists; break }
        '^group create ' { $mock.GroupExists = $true; @{}; break }
        '^apim list ' { ,$mock.ExistingApims; break }
        '^network vnet list ' { ,$mock.ExistingVnets; break }
        '^network private-endpoint list ' { ,$mock.ExistingEndpoints; break }
        '^provider show ' { @{ registrationState = if ($mock.Unregistered) { 'NotRegistered' } else { 'Registered' } }; break }
        '^provider register ' { @{}; break }
        '^deployment group ' {
            $name = $arguments[([array]::IndexOf($arguments, '--name') + 1)]
            if ($arguments[2] -eq 'validate') { @{ properties = @{ provisioningState = 'Succeeded' } }; break }
            if ($arguments[2] -eq 'what-if') { @{ changes = @(@{ resourceId = 'safe-resource-id'; changeType = 'Modify' }) }; break }
            $mock.Deployments.Add($name)
            $file = $arguments[([array]::IndexOf($arguments, '--parameters') + 1)].Substring(1)
            $parameters = (Get-Content -Raw -LiteralPath $file | ConvertFrom-Json -AsHashtable).parameters
            switch ($name) {
                'appGatewayNetwork' { @{ properties = @{ outputs = @{ vnetId = @{ value = $vnetId }; privateEndpointSubnetId = @{ value = "$vnetId/subnets/private-endpoints-subnet" } } } } }
                'foundryPrivateNetwork' {
                    $mock.Manual = $parameters.manualApproval.value
                    $mock.EndpointMappings = @(for ($i = 0; $i -lt $parameters.foundryAccounts.value.Count; $i++) {
                        $account = $parameters.foundryAccounts.value[$i]
                        @{
                            id = $endpointId -replace '-0$', "-$i"
                            accountId = "/subscriptions/$($account.subscriptionId)/resourceGroups/$($account.resourceGroup)/providers/Microsoft.CognitiveServices/accounts/$($account.accountName)"
                        }
                    })
                    @{ properties = @{ outputs = @{ endpoints = @{ value = $mock.EndpointMappings } } } }
                }
                'main' {
                    $mock.MainParameters = $parameters
                    @{ properties = @{ provisioningState = 'Succeeded'; outputs = @{ appGatewayPublicIp = @{ value = '192.0.2.1' } } } }
                }
                default { throw "Unexpected deployment $name." }
            }
            break
        }
        '^apim show ' { $mock.Apim; break }
        '^network private-endpoint dns-zone-group list ' {
            ,@(@{ privateDnsZoneConfigs = @(@{ privateDnsZoneId = '/subscriptions/gateway-sub/resourceGroups/gateway-rg/providers/Microsoft.Network/privateDnsZones/privatelink.openai.azure.com' }) })
            break
        }
        '^network private-dns link vnet list ' { ,@(@{ virtualNetwork = @{ id = $vnetId }; virtualNetworkLinkState = 'Completed' }); break }
        '^network application-gateway show-backend-health ' {
            @{ backendAddressPools = @(@{ backendHttpSettingsCollection = @(@{ servers = @(@{ health = $mock.Health }) }) }) }
            break
        }
        default { throw "Unexpected Azure CLI command: $command" }
    }
    ConvertTo-Json -InputObject $result -Depth 50 -Compress
}

function Invoke-RestMethod {
    param($Uri, $Headers, $TimeoutSec, $MaximumRedirection, $Method, $ContentType, $Body)
    $mock.Requests.Add(@{ Uri = $Uri; Headers = $Headers; Body = $Body; MaximumRedirection = $MaximumRedirection })
    if ($Uri.EndsWith('/models')) {
        return [pscustomobject]@{ data = if ($mock.EmptyModels) { @() } else { @([pscustomobject]@{ id = 'test-model' }) } }
    }
    [pscustomobject]@{ choices = @([pscustomobject]@{ message = [pscustomobject]@{ content = if ($mock.EmptyCompletion) { '' } else { 'OK' } } }) }
}

function Start-Sleep { param($Seconds) }

function Start-ThreadJob {
    param($StreamingHost, $ScriptBlock, [object[]]$ArgumentList)
    $job = & $startThreadJobCommand @PSBoundParameters
    $mock.ProgressJobs.Add($job)
    $job
}

function Write-Progress {
    param($Id, $Activity, $Status, [switch]$Completed)
    if ($Completed) { $mock.ProgressCompletions.Add($Activity) }
}

function Read-Host {
    param([string]$Prompt)
    $mock.Prompts.Add(@{ Text = $Prompt; Deployments = $mock.Deployments.Count })
    if ($mock.Answers.Count -eq 0) { throw "Unexpected interactive prompt: $Prompt" }
    $mock.Answers.Dequeue()
}

try {
    Reset-Mock
    $result = & $helper @target -Preview
    Assert-Equal $result.Status 'PreflightOnly' 'Preview must be explicitly incomplete.'
    Assert-Equal (Test-Path -LiteralPath $stateFile) $false 'Preview must not persist state/secrets.'
    Assert-Equal $mock.Deployments.Count 0 'Preview must not deploy.'
    Assert-Equal $mock.Requests.Count 0 'Preflight must not probe Foundry data plane.'
    Assert-Equal @($mock.Calls | Where-Object { ($_ -join ' ') -match 'group create|provider register|account set' }).Count 0 'Preview must not mutate Azure/global subscription context.'

    Reset-Mock
    $result = & $helper @target -WhatIf
    Assert-Equal $result.Status 'PreflightOnly' 'WhatIf must be read-only.'
    Assert-Equal (Test-Path -LiteralPath $stateFile) $false 'WhatIf must not save keys.'

    Reset-Mock
    $result = & $helper @target
    Assert-Equal $result.Status 'AwaitingHttps' 'Infrastructure bootstrap is not Copilot readiness.'
    Assert-Equal $result.ReadyForCopilot $false 'HTTP bootstrap must remain incomplete.'
    Assert-Equal ($mock.Deployments -join ',') 'appGatewayNetwork,foundryPrivateNetwork,main' 'Gate main deployment behind prepared networking.'
    Assert-Equal $mock.Requests.Count 0 'No credential/model traffic over HTTP.'
    Assert-Equal $mock.MainParameters.foundryAccountSubscriptionId.value 'foundry-sub' 'Preserve cross-subscription Foundry scope.'
    Assert-Equal $mock.MainParameters.enablePrivateNetworking.value $true 'Helper must select private mode.'
    Assert-Equal $mock.Prompts.Count 0 'Noninteractive deployment must not prompt.'
    Assert-Equal $mock.ProgressJobs.Count 0 'Noninteractive deployment must not start an animated indicator.'
    Assert-Equal (Test-Path -LiteralPath $stateFile) $true 'Persist resumable state.'
    $savedKeys = (Get-Content -Raw -LiteralPath $stateFile | ConvertFrom-Json -AsHashtable).parameters.orgKeys.team
    $result = & $helper -SubscriptionId gateway-sub -ResourceGroup gateway-rg -NonInteractive -Confirm:$false
    Assert-Equal (Get-Content -Raw -LiteralPath $stateFile | ConvertFrom-Json -AsHashtable).parameters.orgKeys.team $savedKeys 'Reruns must not rotate keys.'
    foreach ($call in $mock.Calls) {
        Assert-Equal (($call -join ' ') -match 'private-org-key|private-gateway-secret') $false 'Never place secrets in native arguments.'
        Assert-Equal (($call -join ' ') -match 'public-network-access|account set|listKeys') $false 'Never enable Foundry public access or fetch account keys.'
    }
    Assert-Equal @(Get-ChildItem -LiteralPath (Split-Path -Parent $stateFile) -Filter 'parameters-*.json').Count 0 'Clean transient parameter files.'
    if ($IsWindows) {
        $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $rules = (Get-Acl -LiteralPath $stateFile).GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])
        Assert-Equal @($rules | Where-Object { $_.IdentityReference -ne $currentUser }).Count 0 'Saved secrets must grant no other user access.'
    }

    Reset-Mock
    $mock.DelayCommand = 'account show'
    foreach ($answer in @(' deploy ', 'Apply', 'aPpLy', ' apply ')) { $mock.Answers.Enqueue($answer) }
    $result = & $helper @interactiveTarget
    Assert-Equal $result.Status 'AwaitingHttps' 'Accept confirmation words regardless of capitalization or surrounding whitespace.'
    Assert-Equal $mock.Prompts.Count 4 'Confirm the target and each deployment stage.'
    Assert-Equal $mock.Answers.Count 0 'Consume every expected confirmation.'
    Assert-Equal ($mock.ProgressJobs.Count -gt 0) $true 'Show progress while interactive Azure commands run.'
    $progress = @($mock.ProgressJobs[0].Progress)
    Assert-Equal ($progress.Count -ge 2) $true 'Update the indicator while a silent Azure command is still running.'
    Assert-Equal $progress[0].Activity 'checking target subscription authentication' 'Identify the running operation.'
    Assert-Equal (@($progress.StatusDescription | Select-Object -Unique).Count -ge 2) $true 'Advance the spinner instead of showing a static busy message.'
    Assert-Equal ($progress[0].StatusDescription -match '^[|/\\-] Running - \d{2}:\d{2}:\d{2} elapsed$') $true 'Show a spinner and elapsed time rather than a fabricated percentage.'
    Assert-Equal $mock.ProgressCompletions.Count $mock.ProgressJobs.Count 'Clear progress after every successful command.'
    foreach ($job in $mock.ProgressJobs) {
        Assert-Equal $job.State 'Completed' 'Finish indicator workers cleanly, including for fast commands.'
        Assert-Equal @(Get-Job -Id $job.Id -ErrorAction SilentlyContinue).Count 0 'Remove completed indicator workers.'
    }

    Reset-Mock
    foreach ($answer in @('deply', 'DEPLOY', 'aply', 'APPLY', 'APPLY', 'APPLY')) { $mock.Answers.Enqueue($answer) }
    $result = & $helper @interactiveTarget
    Assert-Equal $result.Status 'AwaitingHttps' 'Retry mistyped DEPLOY and APPLY confirmations.'
    Assert-Equal $mock.Prompts.Count 6 'Re-prompt once for each typo.'
    Assert-Equal $mock.Prompts[0].Text $mock.Prompts[1].Text 'Retry the same target confirmation.'
    Assert-Equal $mock.Prompts[2].Text $mock.Prompts[3].Text 'Retry the same stage confirmation.'
    Assert-Equal $mock.Prompts[1].Deployments 0 'A mistyped target confirmation must not authorize deployment.'
    Assert-Equal $mock.Prompts[3].Deployments 0 'A mistyped APPLY must not authorize deployment.'

    Reset-Mock
    foreach ($answer in @('DEPLOY', 'APPLY', 'APPLY', 'APPLY')) { $mock.Answers.Enqueue($answer) }
    $savedProgressPreference = $ProgressPreference
    try {
        $ProgressPreference = 'SilentlyContinue'
        $result = & $helper @interactiveTarget
    } finally {
        $ProgressPreference = $savedProgressPreference
    }
    Assert-Equal $result.Status 'AwaitingHttps' 'Suppressing progress must not change deployment results.'
    Assert-Equal $mock.ProgressJobs.Count 0 'Respect PowerShell progress suppression.'

    foreach ($answer in @(' CANCEL ', '')) {
        Reset-Mock
        $mock.Answers.Enqueue('yes')
        $mock.Answers.Enqueue($answer)
        Assert-Throws { & $helper @interactiveTarget } '^Deployment cancelled\.$'
        Assert-Equal $mock.Prompts.Count 2 'Generic yes must not bypass the required target confirmation word.'
        Assert-Equal $mock.Deployments.Count 0 'Cancelling the target must not deploy.'
        Assert-Equal (Test-Path -LiteralPath $stateFile) $false 'Cancelling the target must not save state.'
        Assert-Equal @($mock.Calls | Where-Object { ($_ -join ' ') -match 'group create|provider register' }).Count 0 'Cancelling the target must not mutate Azure.'

        Reset-Mock
        foreach ($response in @('DEPLOY', 'APPLY', 'APPLY', 'aply', $answer)) { $mock.Answers.Enqueue($response) }
        Assert-Throws { & $helper @interactiveTarget } '^Deployment cancelled after preview\.$'
        Assert-Equal $mock.Prompts.Count 5 'Allow cancellation after a mistyped stage confirmation.'
        Assert-Equal ($mock.Deployments -join ',') 'appGatewayNetwork,foundryPrivateNetwork' 'Cancelling main must preserve completed stages without applying main.'
        Assert-Equal @(Get-ChildItem -LiteralPath (Split-Path -Parent $stateFile) -Filter 'parameters-*.json').Count 0 'Clean transient parameter files after cancellation.'
    }

    Reset-Mock
    foreach ($key in @('foundryAccountName', 'foundryAccountSubscriptionId', 'foundryAccountResourceGroup')) { $script:values.Remove($key) }
    Save-Input
    $result = & $helper @target -FoundryResourceId $accountId
    Assert-Equal $mock.MainParameters.foundryAccountName.value 'existing-foundry' 'Derive account name from resource ID.'
    Assert-Equal $mock.MainParameters.foundryAccountResourceGroup.value 'models-rg' 'Derive Foundry resource group independently from gateway target.'

    Reset-Mock
    $script:values.foundryBackends = @(
        @{ accountName = 'existing-foundry'; backendBaseUrl = 'https://existing-foundry.openai.azure.com' }
        @{ accountName = 'second-foundry'; backendBaseUrl = 'https://second-foundry.openai.azure.com' }
    )
    Save-Input
    $result = & $helper @target
    Assert-Equal $mock.EndpointMappings.Count 2 'Deduplicate primary/pool accounts while preparing every distinct endpoint.'
    Assert-Equal $mock.MainParameters.foundryBackends.value.Count 2 'Preserve advanced pool configuration in main deployment.'
    Assert-Equal @($mock.Calls | Where-Object { ($_ -join ' ') -match 'resource show .*privateEndpoints/.*-1' }).Count 2 'Check pool endpoint approval before and after main deployment.'

    Reset-Mock
    $script:values.foundryPrivateEndpointManualApproval = $true
    Save-Input
    $mock.Approval = 'Pending'
    $result = & $helper @target
    Assert-Equal $result.Status 'AwaitingApproval' 'Manual approval must be resumable.'
    Assert-Equal ($mock.Deployments -contains 'main') $false 'Do not deploy APIM before approval.'
    $mock.Approval = 'Approved'
    $result = & $helper -SubscriptionId gateway-sub -ResourceGroup gateway-rg -NonInteractive -Confirm:$false
    Assert-Equal $result.Status 'AwaitingHttps' 'Resume approved manual connection.'
    Assert-Equal $mock.MainParameters.foundryPrivateEndpointManualApproval.value $true 'Preserve manual mode in final reconciliation.'
    Assert-Throws { & $helper -SubscriptionId gateway-sub -ResourceGroup gateway-rg -NonInteractive -ApimName different-apim -Confirm:$false } 'Saved apimName differs'

    foreach ($status in @('Rejected', 'Disconnected')) {
        Reset-Mock
        $mock.Approval = $status
        Assert-Throws { & $helper @target } $status
        Assert-Equal ($mock.Deployments -contains 'main') $false 'Rejected/disconnected connections must block main deployment.'
    }

    foreach ($addresses in @(@{ value = @() }, @{ value = $null }, @{ value = @('') }, @{})) {
        Reset-Mock
        if ($addresses.ContainsKey('value')) {
            $mock.Apim.privateIpAddresses = $addresses.value
        } else {
            $mock.Apim.Remove('privateIpAddresses')
        }
        Assert-Throws { & $helper @target } '^APIM is not provisioned with an internal private IP\.$'
        Assert-Equal $mock.Requests.Count 0 'Missing private addresses must block readiness verification.'
    }

    Reset-Mock
    $script:values.appGwHttpsPfxBase64 = 'test-certificate'
    $script:values.appGwHttpsPfxPassword = 'test-password'
    Save-Input
    $result = & $helper @target -Hostname gateway.example.com -Model test-model
    Assert-Equal $result.ReadyForCopilot $true 'Only verified HTTPS and completion is ready.'
    Assert-Equal $mock.Requests.Count 2 'Verify discovery and actual inference.'
    Assert-Equal $mock.Requests[0].Uri 'https://gateway.example.com/byok/team/models' 'Probe the public HTTPS gateway, not Foundry/APIM directly.'
    Assert-Equal $mock.Requests[1].MaximumRedirection 0 'Never forward org keys through redirects.'
    $mock.EmptyCompletion = $true
    Assert-Throws { & $helper @target -Hostname gateway.example.com -Model test-model } 'no assistant text'
    $mock.EmptyCompletion = $false
    $mock.EmptyModels = $true
    Assert-Throws { & $helper @target -Hostname gateway.example.com -Model test-model } 'no deployments'
    $mock.EmptyModels = $false
    $mock.Health = 'Unhealthy'
    Assert-Throws { & $helper @target -Hostname gateway.example.com -Model test-model } 'backend is unhealthy'

    Reset-Mock
    $script:values.appGwHttpsPfxBase64 = 'test-certificate'
    $script:values.appGwHttpsPfxPassword = 'test-password'
    Save-Input
    $result = & $helper @target -Hostname gateway.example.com
    Assert-Equal $result.Status 'AwaitingModelVerification' 'Discovery alone is not model readiness.'
    Assert-Equal $result.ReadyForCopilot $false 'Require actual inference before reporting readiness.'

    Reset-Mock
    $mock.Fail = 'deployment group validate'
    $mock.Answers.Enqueue('DEPLOY')
    Assert-Throws { & $helper @interactiveTarget } 'exit 9.*AuthorizationFailed for \[REDACTED\]'
    Assert-Equal $mock.Deployments.Count 0 'Validation failure must prevent deployment.'
    Assert-Equal ($mock.ProgressJobs.Count -gt 0) $true 'Exercise command failures with the indicator active.'
    Assert-Equal $mock.ProgressCompletions.Count $mock.ProgressJobs.Count 'Clear progress even when Azure CLI fails.'
    foreach ($job in $mock.ProgressJobs) {
        Assert-Equal $job.State 'Completed' 'Finish indicator workers cleanly after command failures.'
        Assert-Equal @(Get-Job -Id $job.Id -ErrorAction SilentlyContinue).Count 0 'Remove indicator workers after errors.'
    }
    Assert-Equal @(Get-ChildItem -LiteralPath (Split-Path -Parent $stateFile) -Filter 'parameters-*.json').Count 0 'Clean secrets after errors.'

    Reset-Mock
    $script:values.Remove('orgKeys')
    $script:values.Remove('appGwSharedSecret')
    Save-Input
    Assert-Throws { & $helper @target -Organizations team } 'Missing organization keys'
    $result = & $helper @target -Organizations team -GenerateKeys
    $saved = Get-Content -Raw -LiteralPath $stateFile | ConvertFrom-Json -AsHashtable
    Assert-Equal $saved.parameters.orgKeys.team.Length 64 'Generate strong keys only with explicit consent.'
    Assert-Equal ($saved.parameters.orgKeys.team -ne $saved.parameters.appGwSharedSecret) $true 'Keep org and gateway secrets distinct.'

    Reset-Mock
    $mock.GroupExists = $true
    $mock.ExistingApims = @(@{ name = 'test-apim'; virtualNetworkType = 'None' })
    Assert-Throws { & $helper @target } 'AllowPublicMigration'
    Assert-Equal $mock.Deployments.Count 0 'Existing public deployments require explicit migration consent.'
    $mock.ExistingApims = @()
    $mock.ExistingVnets = @(@{
        name = 'test-apim-appgw-vnet'; addressSpace = @{ addressPrefixes = @('10.50.0.0/16') }
        subnets = @(@{ name = 'appgw-subnet'; addressPrefix = '10.50.0.0/24'; networkSecurityGroup = @{ id = '/governance/nsg' } })
    })
    Assert-Throws { & $helper @target } 'appGwExistingNsgName'
    $mock.ExistingVnets = @()
    $mock.ExistingEndpoints = @(@{
        name = 'test-apim-appgw-foundry-pe-0'; manualPrivateLinkServiceConnections = @()
        privateLinkServiceConnections = @(@{ privateLinkServiceId = '/different/account'; privateLinkServiceConnectionState = @{ status = 'Approved' } })
    })
    Assert-Throws { & $helper @target } 'endpoint target differs'
    $mock.ExistingEndpoints[0].privateLinkServiceConnections[0].privateLinkServiceId = $accountId
    $mock.ExistingEndpoints[0].privateLinkServiceConnections[0].privateLinkServiceConnectionState.status = 'Disconnected'
    Assert-Throws { & $helper @target } 'rejected/disconnected'

    Reset-Mock
    $mock.Unregistered = $true
    Assert-Throws { & $helper @target } 'subscription owner to register'
    Assert-Equal $mock.Deployments.Count 0 'Do not continue without cross-subscription prerequisites.'
    Assert-Equal @($mock.Calls | Where-Object { ($_ -join ' ') -match 'provider register --subscription foundry-sub' }).Count 0 'Never register in Foundry subscription without confirmation.'

    Reset-Mock
    $fakeBicep = Join-Path $scratch 'input.bicepparam'
    [IO.File]::WriteAllText($fakeBicep, '// mocked Bicep compiler')
    $result = & $helper -SubscriptionId gateway-sub -ResourceGroup gateway-rg -ParameterFile $fakeBicep -NonInteractive -Preview
    Assert-Equal $result.Status 'PreflightOnly' 'Use compiler output for Bicep parameter files.'

    Write-Output "PASS: $script:checks deployment-helper checks. All Azure and HTTP operations were mocked."
}
catch {
    Write-Error "$($_.Exception.Message)`n$($_.ScriptStackTrace)" -ErrorAction Continue
    throw
}
finally {
    # Only this test's uniquely named scratch directory is removed.
    Remove-Item -LiteralPath $scratch -Recurse -Force
}
