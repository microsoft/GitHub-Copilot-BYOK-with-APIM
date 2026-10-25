#requires -Version 7.2
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$helper = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\app-gateway.ps1'
$target = @{ ResourceGroup = 'helper-rg'; GatewayName = 'helper-appgw'; Confirm = $false }
$script:checks = 0

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)

    if ($Actual -cne $Expected) {
        throw "$Message Expected '$Expected', got '$Actual'."
    }
    $script:checks++
}

function Assert-Throws {
    param([scriptblock]$Operation, [string]$Pattern)

    try {
        & $Operation | Out-Null
    }
    catch {
        if ($_.Exception.Message -notmatch $Pattern) {
            throw "Unexpected error: $($_.Exception.Message)"
        }
        $script:checks++
        return
    }
    throw "Expected an error matching '$Pattern'."
}

function Reset-Mock {
    param([string]$State)

    $script:mock = @{
        State = $State
        FinalState = $null
        FailOnCall = 0
        InvalidJson = $false
        Calls = [System.Collections.Generic.List[object]]::new()
    }
}

function az {
    $arguments = @($args)
    # Resolve state from the caller, not the helper's script scope.
    $mock.Calls.Add($arguments)
    $global:LASTEXITCODE = 0
    if ($mock.Calls.Count -eq $mock.FailOnCall) {
        $global:LASTEXITCODE = 7
        return
    }

    switch ($arguments[2]) {
        'show' {
            if ($mock.InvalidJson) {
                return '{invalid-json'
            }
            return (@{
                name = 'helper-appgw'
                resourceGroup = 'helper-rg'
                operationalState = $mock.State
                provisioningState = 'Succeeded'
            } | ConvertTo-Json -Compress)
        }
        { $_ -in @('start', 'stop') } {
            $mock.State = if ($null -ne $mock.FinalState) {
                $mock.FinalState
            } elseif ($_ -eq 'start') {
                'Running'
            } else {
                'Stopped'
            }
        }
        default {
            throw "Unexpected Azure CLI command: $($arguments -join ' ')"
        }
    }
}

foreach ($action in @('Start', 'Stop')) {
    $initialState = if ($action -eq 'Start') { 'Stopped' } else { 'Running' }
    $expectedState = if ($action -eq 'Start') { 'Running' } else { 'Stopped' }
    Reset-Mock $initialState
    $result = & $helper -Action $action @target -SubscriptionId 'gateway-subscription'
    Assert-Equal $result.operationalState $expectedState "$action must reach the requested state."
    Assert-Equal $result.provisioningState 'Succeeded' 'Return the provisioning state.'
    Assert-Equal $result.name 'helper-appgw' 'Return the gateway name.'
    Assert-Equal $result.resourceGroup 'helper-rg' 'Return the resource group.'
    Assert-Equal (($script:mock.Calls | ForEach-Object { $_[2] }) -join ',') "show,$($action.ToLowerInvariant()),show" 'Read state before and after the operation.'
    foreach ($call in $script:mock.Calls) {
        Assert-Equal ($call[0..1] -join ' ') 'network application-gateway' 'Use only Application Gateway commands.'
        Assert-Equal $call[([array]::IndexOf($call, '--resource-group') + 1)] 'helper-rg' 'Scope every call to the gateway resource group.'
        Assert-Equal $call[([array]::IndexOf($call, '--name') + 1)] 'helper-appgw' 'Scope every call to the gateway name.'
        Assert-Equal $call[([array]::IndexOf($call, '--subscription') + 1)] 'gateway-subscription' 'Pass the subscription to every call.'
        Assert-Equal ($call -contains '--no-wait') $false 'Wait for Azure CLI operations to complete.'
    }

    Reset-Mock $expectedState
    $result = & $helper -Action $action @target
    Assert-Equal $result.operationalState $expectedState 'Return the state when no operation is needed.'
    Assert-Equal $script:mock.Calls.Count 1 'An already-satisfied request must not mutate the gateway.'
    Assert-Equal ($script:mock.Calls[0] -contains '--subscription') $false 'Use the current subscription when no override is given.'

    Reset-Mock $initialState
    $result = & $helper -Action $action @target -WhatIf
    Assert-Equal $script:mock.Calls.Count 1 'WhatIf must only read the gateway state.'
    Assert-Equal $result.operationalState $initialState 'WhatIf must return the unchanged state.'

    foreach ($failOnCall in @(1, 2, 3)) {
        Reset-Mock $initialState
        $script:mock.FailOnCall = $failOnCall
        Assert-Throws { & $helper -Action $action @target } 'Azure CLI failed \(exit code 7\)'
        Assert-Equal $script:mock.Calls.Count $failOnCall 'Stop immediately after a CLI failure.'
    }

    Reset-Mock $initialState
    $script:mock.FinalState = $initialState
    Assert-Throws { & $helper -Action $action @target } "expected $expectedState"
}

foreach ($state in @('Starting', 'Stopping')) {
    Reset-Mock $state
    Assert-Throws { & $helper -Action Start @target } 'Wait for the current operation'
    Assert-Equal $script:mock.Calls.Count 1 'Do not mutate a gateway while another operation is in progress.'
}

Reset-Mock 'Stopped'
$script:mock.InvalidJson = $true
Assert-Throws { & $helper -Action Start @target } 'JSON'
Assert-Equal $script:mock.Calls.Count 1 'Invalid CLI output must not trigger a mutation.'

Reset-Mock 'Stopped'
Assert-Throws { & $helper -Action Restart @target } 'ValidateSet|does not belong to the set'
Assert-Throws { & $helper -Action Start -ResourceGroup ' ' -GatewayName 'helper-appgw' } 'does not match'
Assert-Throws { & $helper -Action Start -ResourceGroup 'helper-rg' -GatewayName ' ' } 'does not match'
Assert-Throws { & $helper -Action Start @target -SubscriptionId ' ' } 'does not match'
Assert-Equal $script:mock.Calls.Count 0 'Reject invalid input before invoking Azure CLI.'

& {
    function Get-Command {}
    Assert-Throws { & $helper -Action Start @target } 'Azure CLI \(az\) is required'
}
Assert-Equal $script:mock.Calls.Count 0 'Report a missing Azure CLI before doing any work.'

Write-Output "PASS: $script:checks offline Application Gateway helper checks. Azure CLI was mocked; no Azure resources were accessed."
