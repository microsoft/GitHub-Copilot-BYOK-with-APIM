#requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$scratch = Join-Path ([IO.Path]::GetTempPath()) "byok-key-rotation-$([guid]::NewGuid())"
$null = New-Item -ItemType Directory -Path (Join-Path $scratch 'scripts'), (Join-Path $scratch 'infra')
foreach ($name in @('rotate-org-key.ps1', 'private-state.ps1')) {
    Copy-Item -LiteralPath (Join-Path $root "scripts\$name") -Destination (Join-Path $scratch 'scripts')
}
$helper = Join-Path $scratch 'scripts\rotate-org-key.ps1'
. (Join-Path $scratch 'scripts\private-state.ps1')
$statePath = Join-Path $scratch '.azure\deploy\gateway-sub\gateway-rg\state.json'
$parameterPath = Join-Path $scratch 'infra\my.bicepparam'
$pendingPath = Join-Path (Split-Path -Parent $statePath) 'rotation-team.json'
$target = @{ SubscriptionId = 'gateway-sub'; ResourceGroup = 'gateway-rg'; Organization = 'team'; Confirm = $false }
$script:checks = 0

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ($Actual -cne $Expected) { throw $Message }
    $script:checks++
}

function Assert-Throws {
    param([scriptblock]$Operation, [string]$Pattern)
    try { & $Operation | Out-Null }
    catch {
        if ($_.Exception.Message -notmatch $Pattern) { throw "Unexpected error: $($_.Exception.Message)" }
        $script:checks++
        return
    }
    throw "Expected error matching $Pattern."
}

function Reset-Mock {
    if (Test-Path -LiteralPath $pendingPath) { Remove-Item -LiteralPath $pendingPath }
    $script:mock = @{
        RemoteKey = 'original-private-key'; Calls = [Collections.Generic.List[object]]::new()
        FailPatch = $false; FailVerification = $false; Patches = 0; Secret = $true
    }
    Write-PrivateJson $statePath @{
        hostname = 'gateway.example.com'; model = 'test-model'
        parameters = @{
            apimName = 'test-apim'; orgKeys = @{ team = 'original-private-key'; other = 'other-private-key' }
            appGwSharedSecret = 'private-gateway-secret'; appGwHttpsPfxBase64 = 'private-certificate'
        }
    }
    [IO.File]::WriteAllText($parameterPath, @'
using './main.bicep'
param apimName = 'test-apim'
// team: 'do-not-replace-this-comment'
param orgKeys = {
  team: 'original-private-key' // retain this comment
  other: 'other-private-key'
}
param appGwSharedSecret = 'private-gateway-secret'
'@)
}

function bicep {
    $global:LASTEXITCODE = 0
    '{"parameters":{"apimName":{"value":"test-apim"}}}'
}

function az {
    $mock.Calls.Add(@($args))
    $global:LASTEXITCODE = 0
    $method = $args[([array]::IndexOf($args, '--method') + 1)]
    switch ($method) {
        'get' { return (@{ properties = @{ secret = $mock.Secret } } | ConvertTo-Json -Compress) }
        'post' {
            if ($mock.FailVerification -and $mock.Patches -gt 0) { $global:LASTEXITCODE = 9; return 'secret-bearing native error' }
            return (@{ value = $mock.RemoteKey } | ConvertTo-Json -Compress)
        }
        'patch' {
            if ($mock.FailPatch) { $global:LASTEXITCODE = 9; return 'secret-bearing native error' }
            $file = $args[([array]::IndexOf($args, '--body') + 1)].Substring(1)
            $mock.RemoteKey = (Get-Content -Raw -LiteralPath $file | ConvertFrom-Json -AsHashtable).properties.value
            $mock.Patches++
            return '{}'
        }
        default { throw 'Unexpected Azure CLI operation.' }
    }
}

try {
    Reset-Mock
    $beforeState = [IO.File]::ReadAllText($statePath)
    $beforeParameters = [IO.File]::ReadAllText($parameterPath)
    & $helper @target -WhatIf
    Assert-Equal $mock.Patches 0 'WhatIf must not rotate in Azure.'
    Assert-Equal ([IO.File]::ReadAllText($statePath)) $beforeState 'WhatIf must not write state.'
    Assert-Equal ([IO.File]::ReadAllText($parameterPath)) $beforeParameters 'WhatIf must not write parameters.'
    Assert-Equal (Test-Path -LiteralPath $pendingPath) $false 'WhatIf must not generate recovery secrets.'

    $result = & $helper @target
    Assert-Equal $result.Status 'Rotated' 'Return completed rotation.'
    $state = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json -AsHashtable
    $text = [IO.File]::ReadAllText($parameterPath)
    Assert-Equal ($mock.RemoteKey -match '^[0-9a-f]{64}$') $true 'Generate a cryptographically random 32-byte hex key.'
    Assert-Equal $state.parameters.orgKeys.team $mock.RemoteKey 'Synchronize state with APIM.'
    Assert-Equal $text ($beforeParameters.Replace("team: 'original-private-key'", "team: '$($mock.RemoteKey)'")) 'Edit only the selected key literal, retaining comments and other settings.'
    Assert-Equal $state.parameters.orgKeys.other 'other-private-key' 'Preserve other org keys.'
    Assert-Equal $state.parameters.appGwSharedSecret 'private-gateway-secret' 'Preserve gateway secret.'
    Assert-Equal $state.parameters.appGwHttpsPfxBase64 'private-certificate' 'Preserve certificate.'
    Assert-Equal $state.hostname 'gateway.example.com' 'Preserve verification settings.'
    Assert-Equal (Test-Path -LiteralPath $pendingPath) $false 'Remove recovery file after synchronization.'
    foreach ($call in $mock.Calls) {
        Assert-Equal $call[0] 'rest' 'Never redeploy or modify gateway infrastructure.'
        Assert-Equal (($call -join ' ').Contains($mock.RemoteKey)) $false 'Never put a key in CLI arguments.'
        Assert-Equal (($call -join ' ') -match 'namedValues/byokKey-team') $true 'Scope every request to the selected org.'
    }
    if ($IsWindows) {
        $user = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $rules = (Get-Acl -LiteralPath $statePath).GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])
        Assert-Equal @($rules | Where-Object { $_.IdentityReference -ne $user }).Count 0 'Keep saved state user-only.'
    }

    foreach ($failure in @('FailPatch', 'FailVerification')) {
        Reset-Mock
        $mock[$failure] = $true
        Assert-Throws { & $helper @target } 'Azure CLI failed.*exit 9'
        Assert-Equal (Test-Path -LiteralPath $pendingPath) $true 'Retain recoverable secrets after an ambiguous Azure failure.'
        Assert-Equal @(Get-ChildItem -LiteralPath (Split-Path -Parent $statePath) -Filter 'rotation-request-*.json').Count 0 'Clean temporary request body after errors.'
        $pending = Get-Content -Raw -LiteralPath $pendingPath | ConvertFrom-Json -AsHashtable
        Assert-Throws { & $helper @target } 'unfinished rotation'
        $mock[$failure] = $false
        $result = & $helper @target -Resume
        Assert-Equal $result.Status 'Rotated' 'Resume incomplete rotation.'
        Assert-Equal $mock.RemoteKey $pending.newKey 'Resume must reuse the original replacement key.'
    }

    Reset-Mock
    $mock.RemoteKey = 'externally-changed-key'
    Assert-Throws { & $helper @target } 'differs from saved state'
    Assert-Equal $mock.Patches 0 'Reject remote drift before mutation.'
    Reset-Mock
    $mock.Secret = $false
    Assert-Throws { & $helper @target } 'Only secret named values'
    Reset-Mock
    Assert-Throws { & $helper @target -Resume } 'no unfinished rotation'
    Reset-Mock
    $text = [IO.File]::ReadAllText($parameterPath).Replace("team: 'original-private-key'", "team: readEnvironmentVariable('TEAM_KEY')")
    [IO.File]::WriteAllText($parameterPath, $text)
    Assert-Throws { & $helper @target } 'literal strings'
    Assert-Equal $mock.Patches 0 'Reject dynamic parameter expressions before mutation.'
    Reset-Mock
    Remove-Item -LiteralPath $parameterPath
    $result = & $helper @target
    Assert-Equal $result.ParameterFile '' 'Allow saved-state-only deployments and report no parameter file updated.'
    Reset-Mock
    Remove-Item -LiteralPath $statePath
    Assert-Throws { & $helper @target } 'Saved deployment state is required'
    Write-Output "PASS: $script:checks key-rotation helper checks. All Azure operations were mocked."
}
finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force
}
