[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('byok-deployment-tests-' + [guid]::NewGuid())
$templatePath = Join-Path $scratch 'main.json'
$parametersPath = Join-Path $scratch 'starter.parameters.json'
$overridesSourcePath = Join-Path $root ('infra\.validation-overrides-' + [guid]::NewGuid() + '.bicepparam')
$overridesPath = Join-Path $scratch 'overrides.parameters.json'
$script:checks = 0

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)

    if ($Actual -cne $Expected) {
        throw $Message
    }
    $script:checks++
}

New-Item -ItemType Directory -Path $scratch | Out-Null
try {
    & bicep build (Join-Path $root 'infra\main.bicep') --outfile $templatePath
    if ($LASTEXITCODE -ne 0) {
        throw 'Bicep template compilation failed.'
    }
    & bicep build-params (Join-Path $root 'infra\example.bicepparam') --outfile $parametersPath
    if ($LASTEXITCODE -ne 0) {
        throw 'Starter parameter compilation failed.'
    }

    $starterSource = Get-Content -Raw -LiteralPath (Join-Path $root 'infra\example.bicepparam')
    $withOverrides = [regex]::Replace($starterSource, '(?m)^// (?=param |[ \t]|[}\]])', '')
    [IO.File]::WriteAllText($overridesSourcePath, $withOverrides)
    & bicep build-params $overridesSourcePath --outfile $overridesPath
    if ($LASTEXITCODE -ne 0) {
        throw 'Commented starter override examples failed to compile.'
    }

    $template = Get-Content -Raw -LiteralPath $templatePath | ConvertFrom-Json
    $starter = Get-Content -Raw -LiteralPath $parametersPath | ConvertFrom-Json
    $overrides = Get-Content -Raw -LiteralPath $overridesPath | ConvertFrom-Json
    $parameters = $template.parameters

    foreach ($name in @('apimSkuName', 'orgModels', 'foundryProjectName', 'appGwExistingNsgName')) {
        Assert-Equal ($overrides.parameters.PSObject.Properties.Name -contains $name) $true "Commented example was not validated: $name."
    }
    Assert-Equal $parameters.deployAppGateway.defaultValue $true 'Application Gateway must be the template default.'
    Assert-Equal $starter.parameters.deployAppGateway.value $true 'The starter must explicitly include Application Gateway.'
    Assert-Equal @($starter.parameters.PSObject.Properties).Count 8 'The starter must contain only seven inputs and the gateway flag.'
    Assert-Equal $starter.parameters.foundryAccountSubscriptionId.value '<foundry-subscription-id>' 'The starter must explicitly include the Foundry subscription ID.'
    Assert-Equal $parameters.foundryAccountSubscriptionId.defaultValue '[subscription().subscriptionId]' 'The template must retain its same-subscription default for compatibility.'
    Assert-Equal $parameters.appGwName.defaultValue "[format('{0}-appgw', parameters('apimName'))]" 'Gateway naming must derive from APIM.'
    Assert-Equal $parameters.appGwExistingNsgName.defaultValue '' 'Existing-NSG reuse must be opt-in.'
    Assert-Equal $parameters.foundryBackendBaseUrl.defaultValue "[format('https://{0}.openai.azure.com', parameters('foundryAccountName'))]" 'The standard Foundry endpoint must be inferred.'
    Assert-Equal $parameters.orgs.defaultValue "[objectKeys(parameters('orgKeys'))]" 'Organization slugs must derive from the key map.'
    Assert-Equal $parameters.orgs.minLength 1 'At least one organization must be configured.'
    Assert-Equal $parameters.appGwEnableHttps.defaultValue "[not(empty(parameters('appGwHttpsPfxBase64')))]" 'A supplied certificate must enable HTTPS by default.'

    foreach ($name in @('orgKeys', 'appGwSharedSecret', 'appGwHttpsPfxBase64', 'appGwHttpsPfxPassword')) {
        Assert-Equal ($parameters.$name.type -in @('secureObject', 'secureString')) $true "$name must remain secure."
    }
    foreach ($name in @('deployObservability', 'deployContentSafety', 'deploySemanticCache', 'enableTokenMetrics')) {
        Assert-Equal $parameters.$name.defaultValue $false "$name must remain opt-in."
        Assert-Equal ($starter.parameters.PSObject.Properties.Name -contains $name) $false "The starter must not override $name."
    }

    $gateway = @($template.resources | Where-Object { $_.type -eq 'Microsoft.Resources/deployments' -and $_.name -eq 'appGateway' })
    Assert-Equal $gateway.Count 1 'Exactly one gateway module must be present.'
    Assert-Equal $gateway[0].condition "[parameters('deployAppGateway')]" 'The explicit APIM-only opt-out must remain effective.'
    Assert-Equal $gateway[0].properties.parameters.sharedSecret.value "[variables('validatedAppGwSharedSecret')]" 'Gateway must use the validated secret.'
    Assert-Equal $gateway[0].properties.parameters.enableHttps.value "[variables('appGwHttpsReady')]" 'Gateway must use validated HTTPS settings.'
    Assert-Equal $gateway[0].properties.parameters.existingNsgName.value "[parameters('appGwExistingNsgName')]" 'Gateway must receive the existing-NSG selection.'

    $namedValue = @($template.resources | Where-Object { $_.type -eq 'Microsoft.ApiManagement/service/namedValues' -and $_.name -like '*appGwSecret*' })
    Assert-Equal $namedValue.Count 1 'The APIM gateway-secret named value must be present.'
    Assert-Equal $namedValue[0].properties.value "[variables('validatedAppGwSharedSecret')]" 'APIM and Application Gateway must share the validated secret.'
    Assert-Equal $template.variables.validatedAppGwSharedSecret "[if(or(not(parameters('deployAppGateway')), greaterOrEquals(length(parameters('appGwSharedSecret')), 32)), parameters('appGwSharedSecret'), fail('Application Gateway requires appGwSharedSecret with at least 32 characters. Generate it once with openssl rand -hex 32 and keep it for redeployments.'))]" 'Missing or short gateway secrets must fail, except in APIM-only mode.'
    Assert-Equal $template.variables.appGwHttpsReady "[if(not(parameters('appGwEnableHttps')), false(), if(not(parameters('deployAppGateway')), fail('HTTPS requires deployAppGateway = true. Remove the certificate settings or enable Application Gateway.'), if(or(empty(parameters('appGwHttpsPfxBase64')), empty(parameters('appGwHttpsPfxPassword'))), fail('HTTPS requires both appGwHttpsPfxBase64 and appGwHttpsPfxPassword.'), true())))]" 'HTTPS validation must reject a disabled gateway and incomplete certificate settings.'

    $networkResources = $gateway[0].properties.template.resources
    $appGateway = @($networkResources | Where-Object { $_.type -eq 'Microsoft.Network/applicationGateways' })
    Assert-Equal $appGateway.Count 1 'The module must deploy an Application Gateway resource.'
    Assert-Equal $appGateway[0].properties.sku.name 'WAF_v2' 'The gateway must use WAF_v2.'

    $chatPolicies = @($template.resources | Where-Object {
        $_.type -eq 'Microsoft.ApiManagement/service/apis/operations/policies' -and
        $_.properties.value.Contains('__NORMALIZE_OPENAI_TOKEN_LIMITS__')
    })
    Assert-Equal $chatPolicies.Count 1 'The chat operation must apply token compatibility by backend contract.'
    Assert-Equal $chatPolicies[0].properties.value.Contains("contains(parameters('cohereOrgs')") $true 'Retain the alternate Cohere backend request contract.'
    Assert-Equal $chatPolicies[0].properties.value.Contains("contains(parameters('mcOrgs')") $true 'Retain the alternate managed-compute backend request contract.'
    Assert-Equal $chatPolicies[0].properties.value.Contains("'false', 'true'") $true 'Enable canonical token limits automatically for the Foundry OpenAI backend.'

    $openApi = Get-Content -LiteralPath (Join-Path $root 'infra\openapi\byok-proxy.openapi.json') -Raw | ConvertFrom-Json
    $chatSchema = $openApi.paths.'/chat/completions'.post.requestBody.content.'application/json'.schema
    Assert-Equal $chatSchema.properties.max_tokens.deprecated $true 'Document the deprecated client limit.'
    Assert-Equal $chatSchema.properties.max_completion_tokens.type 'integer' 'Document the canonical completion budget.'

    $nsgModule = @($networkResources | Where-Object { $_.type -eq 'Microsoft.Resources/deployments' -and $_.name -eq 'appGatewayNsg' })
    Assert-Equal $nsgModule.Count 1 'The gateway must deploy its networking through the standalone NSG module.'
    $nsgDeployment = $nsgModule[0].properties
    Assert-Equal $nsgDeployment.mode 'Incremental' 'NSG deployment must preserve unrelated resources.'
    Assert-Equal $nsgDeployment.parameters.nsgName "[if(empty(parameters('existingNsgName')), createObject('value', format('{0}-nsg', parameters('appGwName'))), createObject('value', parameters('existingNsgName')))]" 'Use the existing NSG name or the stable gateway-derived default.'
    Assert-Equal $nsgDeployment.parameters.reuseExisting.value "[not(empty(parameters('existingNsgName')))]" 'An existing NSG must select child-rule-only mode.'
    Assert-Equal $nsgDeployment.parameters.enableHttps.value "[parameters('enableHttps')]" 'Ingress must match the validated listeners.'
    Assert-Equal $nsgDeployment.parameters.subnetAddressPrefix.value "[parameters('subnetAddressPrefix')]" 'Client ingress must target the gateway subnet.'

    $nsgTemplate = $nsgDeployment.template
    Assert-Equal $nsgTemplate.parameters.reuseExisting.defaultValue $false 'The standalone module must default to repository-owned networking.'
    Assert-Equal (($nsgTemplate.variables.httpClientPorts) -join ',') '80' 'Bootstrap must allow only the HTTP listener.'
    Assert-Equal (($nsgTemplate.variables.httpsClientPorts) -join ',') '80,443' 'HTTPS must retain the HTTP redirect and allow TLS.'
    $clientRule = $nsgTemplate.variables.clientIngressRule
    Assert-Equal $clientRule.name 'AllowByokClientIngress' 'The application client rule must have a stable name.'
    Assert-Equal $clientRule.properties.priority 1000 'The client rule must precede the default deny.'
    Assert-Equal $clientRule.properties.direction 'Inbound' 'Client access must not change outbound rules.'
    Assert-Equal $clientRule.properties.access 'Allow' 'Expected public clients must be allowed.'
    Assert-Equal $clientRule.properties.protocol 'Tcp' 'Only TCP client traffic is needed.'
    Assert-Equal $clientRule.properties.sourceAddressPrefix 'Internet' 'Enterprise clients need the public gateway entry point.'
    Assert-Equal $clientRule.properties.sourcePortRange '*' 'Clients must be allowed to use ephemeral source ports.'
    Assert-Equal $clientRule.properties.destinationAddressPrefix "[parameters('subnetAddressPrefix')]" 'Restrict the rule destination to the gateway subnet.'
    Assert-Equal $clientRule.properties.destinationPortRanges "[if(parameters('enableHttps'), variables('httpsClientPorts'), variables('httpClientPorts'))]" 'Open only the active listener ports.'

    $managedNsg = @($nsgTemplate.resources | Where-Object { $_.type -eq 'Microsoft.Network/networkSecurityGroups' })
    Assert-Equal $managedNsg.Count 1 'New deployments must define one NSG.'
    Assert-Equal $managedNsg[0].condition "[not(parameters('reuseExisting'))]" 'Existing-NSG mode must not write the NSG parent.'
    Assert-Equal @($managedNsg[0].properties.securityRules).Count 2 'Only client and GatewayManager custom rules are needed.'
    Assert-Equal $managedNsg[0].properties.securityRules[0] "[variables('clientIngressRule')]" 'Both modes must use the same client-rule definition.'
    $managerRule = $managedNsg[0].properties.securityRules[1]
    Assert-Equal $managerRule.name 'AllowGatewayManager' 'New NSGs must allow gateway infrastructure traffic.'
    Assert-Equal $managerRule.properties.priority 1100 'GatewayManager must precede the default deny.'
    Assert-Equal $managerRule.properties.protocol 'Tcp' 'GatewayManager infrastructure uses TCP.'
    Assert-Equal $managerRule.properties.sourceAddressPrefix 'GatewayManager' 'Do not expose management ports to arbitrary clients.'
    Assert-Equal $managerRule.properties.sourcePortRange '*' 'Do not restrict GatewayManager source ports.'
    Assert-Equal $managerRule.properties.destinationAddressPrefix '*' 'GatewayManager must reach the gateway infrastructure.'
    Assert-Equal $managerRule.properties.destinationPortRange '65200-65535' 'Use the required v2 management ports.'
    Assert-Equal $managerRule.properties.access 'Allow' 'GatewayManager traffic must remain allowed.'
    Assert-Equal $managerRule.properties.direction 'Inbound' 'The management rule must be inbound.'
    Assert-Equal ($managedNsg[0].properties.PSObject.Properties.Name -contains 'defaultSecurityRules') $false 'Do not replace platform default rules.'
    Assert-Equal @($managedNsg[0].properties.securityRules | Where-Object { $_ -isnot [string] -and $_.properties.direction -eq 'Outbound' }).Count 0 'Do not add outbound deny rules.'

    $existingRule = @($nsgTemplate.resources | Where-Object { $_.type -eq 'Microsoft.Network/networkSecurityGroups/securityRules' })
    Assert-Equal $existingRule.Count 1 'Existing NSGs must receive only the application client rule.'
    Assert-Equal $existingRule[0].condition "[parameters('reuseExisting')]" 'Deploy the child rule only when reusing an NSG.'
    Assert-Equal $existingRule[0].name "[format('{0}/{1}', parameters('nsgName'), variables('clientIngressRule').name)]" 'Update the application rule under the selected NSG.'
    Assert-Equal $existingRule[0].properties "[variables('clientIngressRule').properties]" 'Existing NSGs must use the identical client rule without replacing other rules.'
    Assert-Equal $nsgTemplate.outputs.networkSecurityGroupId.value "[resourceId('Microsoft.Network/networkSecurityGroups', parameters('nsgName'))]" 'Return only the selected NSG resource ID.'

    $vnet = @($networkResources | Where-Object { $_.type -eq 'Microsoft.Network/virtualNetworks' })
    Assert-Equal $vnet.Count 1 'The gateway must retain its dedicated VNet.'
    Assert-Equal ($vnet[0].properties.subnets[0].properties.networkSecurityGroup.id -match "^\[reference\(resourceId\('Microsoft.Resources/deployments', 'appGatewayNsg'\), '[^']+'\)\.outputs\.networkSecurityGroupId\.value\]$") $true 'The inline subnet must retain the selected NSG association.'
    Assert-Equal ($vnet[0].dependsOn -contains "[resourceId('Microsoft.Resources/deployments', 'appGatewayNsg')]") $true 'Deploy NSG rules before associating the subnet.'
    Assert-Equal @($networkResources | Where-Object { $_.type -eq 'Microsoft.Network/virtualNetworks/subnets' }).Count 0 'Do not compete with the inline subnet declaration.'
    Assert-Equal $template.outputs.appGatewayNetworkSecurityGroupId.type 'string' 'Expose the selected NSG ID as a non-secret output.'
    Assert-Equal ($template.outputs.appGatewayNetworkSecurityGroupId.value -match "^\[if\(parameters\('deployAppGateway'\), .+\.outputs\.networkSecurityGroupId\.value, ''\)\]$") $true 'APIM-only deployments must report no gateway NSG.'

    $summary = $template.outputs.deploymentSummary.value
    Assert-Equal $summary.applicationGatewayEnabled "[parameters('deployAppGateway')]" 'The summary must report actual gateway enablement.'
    Assert-Equal $summary.httpsEnabled "[variables('appGwHttpsReady')]" 'The summary must report validated HTTPS enablement.'
    Assert-Equal (($summary.PSObject.Properties.Name | Sort-Object) -join ',') 'applicationGatewayEnabled,applicationGatewayId,applicationGatewayName,httpsEnabled,organizations,wafMode' 'The summary must contain only deployment status, names, and resource IDs.'

    $source = Get-Content -Raw -LiteralPath (Join-Path $root 'infra\main.bicep')
    $reference = Get-Content -Raw -LiteralPath (Join-Path $root 'docs\parameters.md')
    $declarations = @{}
    foreach ($declaration in [regex]::Matches($source, '(?m)^param (?<name>\w+) \w+(?: = (?<default>[^\r\n]+))?\r?$')) {
        $declarations[$declaration.Groups['name'].Value] = if ($declaration.Groups['default'].Success) {
            $declaration.Groups['default'].Value.Trim()
        } else {
            'Required'
        }
    }
    $documented = @{}
    foreach ($row in [regex]::Matches($reference, '(?m)^\| `(?<name>\w+)` \| (?<type>[^|]+) \| (?<default>[^|]+) \|')) {
        $name = $row.Groups['name'].Value
        Assert-Equal $documented.ContainsKey($name) $false "$name must appear only once in the parameter reference."
        Assert-Equal $declarations.ContainsKey($name) $true "Unknown parameter in reference: $name."
        $expectedType = $parameters.$name.type -replace 'secureObject', 'secure object' -replace 'secureString', 'secure string'
        Assert-Equal $row.Groups['type'].Value.Trim() $expectedType "$name has an incorrect documented type."
        Assert-Equal $row.Groups['default'].Value.Trim().Trim('`') $declarations[$name] "$name has an incorrect documented default."
        $documented[$name] = $true
    }
    foreach ($name in $declarations.Keys) {
        Assert-Equal $documented.ContainsKey($name) $true "Parameter is missing from the reference: $name."
    }

    Write-Output "PASS: $script:checks offline deployment-contract checks. No Azure resources were accessed."
}
finally {
    foreach ($path in @($templatePath, $parametersPath, $overridesSourcePath, $overridesPath)) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path
        }
    }
    Remove-Item -LiteralPath $scratch
}
