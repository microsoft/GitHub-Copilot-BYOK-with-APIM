#requires -Version 7.2
<#
.SYNOPSIS
Rotates one organization's client key without redeploying infrastructure.
.DESCRIPTION
Updates the APIM secret named value, saved deployment state, and infra\my.bicepparam
when present (or -ParameterFile). Keys are never printed or put in CLI arguments.
Client credentials must be updated manually; see docs\key-rotation.md.
.EXAMPLE
.\scripts\rotate-org-key.ps1 -SubscriptionId <id> -ResourceGroup <rg> -Organization <org> -WhatIf
.EXAMPLE
.\scripts\rotate-org-key.ps1 -SubscriptionId <id> -ResourceGroup <rg> -Organization <org>
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9-]+$')][string]$SubscriptionId,
    [Parameter(Mandatory)][ValidatePattern('^[\w.()-]+$')][string]$ResourceGroup,
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9]+(?:-[a-z0-9]+)*$')][string]$Organization,
    [string]$ParameterFile,
    [switch]$Resume
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'private-state.ps1')
$statePath = Join-Path $root ".azure\deploy\$SubscriptionId\$ResourceGroup\state.json"
$pendingPath = Join-Path (Split-Path -Parent $statePath) "rotation-$Organization.json"
$requestPath = $null

function Invoke-RotationAz {
    param([string]$Operation, [string[]]$Arguments)
    $output = & az @Arguments --only-show-errors --output json 2>&1
    if ($LASTEXITCODE -ne 0) {
        # Native errors can echo request bodies or secret values.
        throw "Azure CLI failed during $Operation (exit $LASTEXITCODE). Inspect the APIM Activity log; native output is withheld to protect keys."
    }
    if ($output) { ($output -join [Environment]::NewLine) | ConvertFrom-Json -AsHashtable }
}

function Get-KeyLiteral {
    param([string]$Text)
    $tokens = @([regex]::Matches($Text, "'(?:[^'\\]|\\.)*'|//[^\r\n]*|/\*[\s\S]*?\*/|[A-Za-z_][A-Za-z0-9_-]*|[^\s]") |
        Where-Object { -not $_.Value.StartsWith('//') -and -not $_.Value.StartsWith('/*') })
    $blocks = @(for ($i = 0; $i -lt $tokens.Count - 3; $i++) {
        if ($tokens[$i].Value -eq 'param' -and $tokens[$i + 1].Value -eq 'orgKeys' -and
            $tokens[$i + 2].Value -eq '=' -and $tokens[$i + 3].Value -eq '{') { $i + 4 }
    })
    if ($blocks.Count -ne 1) { throw 'Parameter file must contain one literal param orgKeys object; expression-based keys require manual synchronization.' }
    $keyMatches = @()
    $i = $blocks[0]
    while ($i -lt $tokens.Count -and $tokens[$i].Value -ne '}') {
        if ($i + 2 -ge $tokens.Count -or $tokens[$i + 1].Value -ne ':' -or
            $tokens[$i + 2].Value -notmatch "^'[^'\\`$]*'$") {
            throw 'orgKeys entries must be literal strings; expression-based keys require manual synchronization.'
        }
        if ($tokens[$i].Value.Trim("'") -ceq $Organization) { $keyMatches += $tokens[$i + 2] }
        $i += 3
    }
    if ($keyMatches.Count -ne 1) { throw "Parameter file must contain exactly one literal key for $Organization." }
    $keyMatches[0]
}

try {
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'Azure CLI (az) is required.' }
    if (-not (Test-Path -LiteralPath $statePath)) { throw 'Saved deployment state is required. This helper does not create deployments.' }
    $stateText = [IO.File]::ReadAllText($statePath)
    $state = $stateText | ConvertFrom-Json -AsHashtable
    if (-not $state['parameters'] -or -not $state.parameters['orgKeys'] -or
        -not $state.parameters.orgKeys.ContainsKey($Organization)) { throw "No saved client key for $Organization." }
    $apimName = $state.parameters.apimName
    if ($apimName -notmatch '^[a-zA-Z][a-zA-Z0-9-]{0,48}[a-zA-Z0-9]$') { throw 'Invalid saved APIM name.' }
    $uri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.ApiManagement/service/$apimName/namedValues/byokKey-${Organization}?api-version=2024-05-01"
    $valueUri = $uri.Replace('?api-version=', '/listValue?api-version=')
    $metadata = Invoke-RotationAz 'reading organization named value' @('rest', '--method', 'get', '--url', $uri)
    if (-not $metadata.properties.secret -or $metadata.properties['keyVault']) { throw 'Only secret named values stored directly in APIM are supported; Key Vault-backed values require manual rotation.' }

    if (Test-Path -LiteralPath $pendingPath) {
        if (-not $Resume) { throw "An unfinished rotation exists at $pendingPath. Use -Resume rather than generating another key." }
        $pending = Get-Content -Raw -LiteralPath $pendingPath | ConvertFrom-Json -AsHashtable
        if ($pending.apimName -cne $apimName -or $pending.organization -cne $Organization) { throw 'Pending rotation identity differs from saved state.' }
        if ($ParameterFile -and (Resolve-Path -LiteralPath $ParameterFile).Path -cne $pending.parameterPath) { throw 'Resume must use the original parameter file.' }
        if ($stateText -cne $pending.originalState -and $stateText -cne $pending.updatedState) { throw 'Saved state changed since rotation began. Reconcile the private recovery file manually before resuming.' }
    } else {
        if ($Resume) { throw 'There is no unfinished rotation to resume.' }
        if (-not $ParameterFile -and (Test-Path -LiteralPath (Join-Path $root 'infra\my.bicepparam'))) {
            $ParameterFile = Join-Path $root 'infra\my.bicepparam'
        }
        $parameterPath = ''
        $parameterText = ''
        if ($ParameterFile) {
            $parameterPath = (Resolve-Path -LiteralPath $ParameterFile).Path
            if ([IO.Path]::GetExtension($parameterPath) -ne '.bicepparam') { throw 'ParameterFile must be a .bicepparam file.' }
            if (-not (Get-Command bicep -ErrorAction SilentlyContinue)) { throw 'Bicep CLI is required to validate the parameter file.' }
            $compiled = & bicep build-params $parameterPath --stdout 2>&1
            if ($LASTEXITCODE -ne 0) { throw 'Parameter compilation failed. Compiler output is withheld to protect keys.' }
            $document = ($compiled -join [Environment]::NewLine) | ConvertFrom-Json -AsHashtable
            if ($document.ContainsKey('parametersJson')) { $document = $document.parametersJson | ConvertFrom-Json -AsHashtable }
            if ($document.parameters.apimName.value -cne $apimName) { throw 'Parameter file APIM name differs from saved deployment. Correct it before rotating.' }
            $parameterText = [IO.File]::ReadAllText($parameterPath)
            $literal = Get-KeyLiteral $parameterText
        }
        $pending = @{
            apimName = $apimName; organization = $Organization
            originalState = $stateText; parameterPath = $parameterPath; originalParameters = $parameterText
        }
    }
    $remote = Invoke-RotationAz 'reading current organization key privately' @('rest', '--method', 'post', '--url', $valueUri)
    $oldKey = $state.parameters.orgKeys[$Organization]
    if ($Resume) {
        if ($remote.value -cne $pending.oldKey -and $remote.value -cne $pending.newKey) { throw 'APIM key changed outside this rotation. Reconcile the private recovery file manually.' }
        if ($pending.parameterPath) {
            $currentText = [IO.File]::ReadAllText($pending.parameterPath)
            if ($currentText -cne $pending.originalParameters -and $currentText -cne $pending.updatedParameters) { throw 'Parameter file changed since rotation began. Reconcile it before resuming.' }
        }
    } elseif ($remote.value -cne $oldKey) {
        throw 'APIM key differs from saved state. Synchronize existing keys before rotating to avoid overwriting another change.'
    }
    Write-Warning "Rotating $Organization invalidates its old client key after APIM propagation. Client settings must be updated manually."
    if (-not $PSCmdlet.ShouldProcess("$SubscriptionId / $ResourceGroup / $apimName / $Organization", 'Rotate organization key and synchronize local configuration')) { return }
    if (-not $Resume) {
        $newKey = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).ToLowerInvariant()
        $pending.oldKey = $oldKey
        $pending.newKey = $newKey
        $state.parameters.orgKeys[$Organization] = $newKey
        $pending.updatedState = $state | ConvertTo-Json -Depth 100
        $pending.updatedParameters = if ($pending.parameterPath) {
            $parameterText.Remove($literal.Index, $literal.Length).Insert($literal.Index, "'$newKey'")
        } else { '' }
        Write-PrivateJson $pendingPath $pending
    }
    $requestPath = Join-Path (Split-Path -Parent $statePath) "rotation-request-$([guid]::NewGuid()).json"
    Write-PrivateJson $requestPath @{ properties = @{ value = $pending.newKey } }
    $null = Invoke-RotationAz 'updating only the organization named value' @('rest', '--method', 'patch', '--url', $uri,
        '--headers', 'If-Match=*', '--body', "@$requestPath")
    $verified = Invoke-RotationAz 'verifying the updated key privately' @('rest', '--method', 'post', '--url', $valueUri)
    if ($verified.value -cne $pending.newKey) { throw 'APIM has not returned the new key. Resume this rotation after propagation; do not generate another key.' }
    if ($pending.parameterPath) { [IO.File]::WriteAllText($pending.parameterPath, $pending.updatedParameters) }
    Write-PrivateJson $statePath ($pending.updatedState | ConvertFrom-Json -AsHashtable)
    Remove-Item -LiteralPath $pendingPath
    Write-Host "Rotated $Organization. Retrieve the new key privately from parameters.orgKeys.$Organization in $statePath; it is not printed."
    if (-not $pending.parameterPath) { Write-Warning 'No parameter file was updated. Synchronize any other private parameter copies before redeploying.' }
    Write-Host "Next: update VS Code, Copilot CLI, GitHub enterprise custom models, and any other consumers. Instructions: $(Join-Path $root 'docs\key-rotation.md')"
    [pscustomobject]@{ Status = 'Rotated'; Organization = $Organization; StatePath = $statePath; ParameterFile = $pending.parameterPath }
}
catch {
    if (Test-Path -LiteralPath $pendingPath) {
        Write-Warning "Rotation may be partially applied. Private recovery data is retained at $pendingPath. Fix the reported cause and rerun with -Resume; do not redeploy stale parameters."
    }
    throw
}
finally {
    if ($requestPath -and (Test-Path -LiteralPath $requestPath)) { Remove-Item -LiteralPath $requestPath }
}
