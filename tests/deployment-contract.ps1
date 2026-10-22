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

    foreach ($name in @('apimSkuName', 'orgModels', 'foundryProjectName')) {
        Assert-Equal ($overrides.parameters.PSObject.Properties.Name -contains $name) $true "Commented example was not validated: $name."
    }
    Assert-Equal $parameters.deployAppGateway.defaultValue $true 'Application Gateway must be the template default.'
    Assert-Equal $starter.parameters.deployAppGateway.value $true 'The starter must explicitly include Application Gateway.'
    Assert-Equal @($starter.parameters.PSObject.Properties).Count 8 'The starter must contain only seven inputs and the gateway flag.'
    Assert-Equal $starter.parameters.foundryAccountSubscriptionId.value '<foundry-subscription-id>' 'The starter must explicitly include the Foundry subscription ID.'
    Assert-Equal $parameters.foundryAccountSubscriptionId.defaultValue '[subscription().subscriptionId]' 'The template must retain its same-subscription default for compatibility.'
    Assert-Equal $parameters.appGwName.defaultValue "[format('{0}-appgw', parameters('apimName'))]" 'Gateway naming must derive from APIM.'
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

    $namedValue = @($template.resources | Where-Object { $_.type -eq 'Microsoft.ApiManagement/service/namedValues' -and $_.name -like '*appGwSecret*' })
    Assert-Equal $namedValue.Count 1 'The APIM gateway-secret named value must be present.'
    Assert-Equal $namedValue[0].properties.value "[variables('validatedAppGwSharedSecret')]" 'APIM and Application Gateway must share the validated secret.'
    Assert-Equal $template.variables.validatedAppGwSharedSecret "[if(or(not(parameters('deployAppGateway')), greaterOrEquals(length(parameters('appGwSharedSecret')), 32)), parameters('appGwSharedSecret'), fail('Application Gateway requires appGwSharedSecret with at least 32 characters. Generate it once with openssl rand -hex 32 and keep it for redeployments.'))]" 'Missing or short gateway secrets must fail, except in APIM-only mode.'
    Assert-Equal $template.variables.appGwHttpsReady "[if(not(parameters('appGwEnableHttps')), false(), if(not(parameters('deployAppGateway')), fail('HTTPS requires deployAppGateway = true. Remove the certificate settings or enable Application Gateway.'), if(or(empty(parameters('appGwHttpsPfxBase64')), empty(parameters('appGwHttpsPfxPassword'))), fail('HTTPS requires both appGwHttpsPfxBase64 and appGwHttpsPfxPassword.'), true())))]" 'HTTPS validation must reject a disabled gateway and incomplete certificate settings.'

    $networkResources = $gateway[0].properties.template.resources
    $appGateway = @($networkResources | Where-Object { $_.type -eq 'Microsoft.Network/applicationGateways' })
    Assert-Equal $appGateway.Count 1 'The module must deploy an Application Gateway resource.'
    Assert-Equal $appGateway[0].properties.sku.name 'WAF_v2' 'The gateway must use WAF_v2.'

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
