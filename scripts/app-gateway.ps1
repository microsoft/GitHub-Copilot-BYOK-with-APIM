#requires -Version 7.2
<#
.SYNOPSIS
Starts or stops an existing Azure Application Gateway.
.DESCRIPTION
Requires Azure CLI and an authenticated Azure session. Uses the current subscription
unless SubscriptionId is supplied. Waits for the operation and verifies its final state.
Stopping the gateway interrupts all traffic until it is started again.
.EXAMPLE
.\scripts\app-gateway.ps1 -Action Start -ResourceGroup my-rg -GatewayName my-apim-appgw
.EXAMPLE
.\scripts\app-gateway.ps1 -Action Stop -ResourceGroup my-rg -GatewayName my-apim-appgw -WhatIf
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Start', 'Stop')]
    [string]$Action,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [ValidatePattern('\S')]
    [string]$ResourceGroup,

    [Parameter(Mandatory)]
    [Alias('Name')]
    [ValidateNotNullOrEmpty()]
    [ValidatePattern('\S')]
    [string]$GatewayName,

    [ValidateNotNullOrEmpty()]
    [ValidatePattern('\S')]
    [string]$SubscriptionId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI (az) is required. Install Azure CLI and sign in with az login.'
}

function Invoke-AzureCli {
    param([string[]]$Arguments)

    $output = & az @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI failed (exit code $LASTEXITCODE): az $($Arguments -join ' ')"
    }
    $output
}

$targetArguments = @('--resource-group', $ResourceGroup, '--name', $GatewayName, '--only-show-errors')
if ($PSBoundParameters.ContainsKey('SubscriptionId')) {
    $targetArguments += @('--subscription', $SubscriptionId)
}
$showArguments = @('network', 'application-gateway', 'show') + $targetArguments + @(
    '--query', '{name:name,resourceGroup:resourceGroup,operationalState:operationalState,provisioningState:provisioningState}',
    '--output', 'json'
)
$gateway = Invoke-AzureCli -Arguments $showArguments | ConvertFrom-Json
$expectedState = if ($Action -eq 'Start') { 'Running' } else { 'Stopped' }

if ($gateway.operationalState -eq $expectedState) {
    Write-Host "Application Gateway '$GatewayName' is already $expectedState."
    return $gateway
}
if ($gateway.operationalState -notin @('Running', 'Stopped')) {
    throw "Application Gateway '$GatewayName' is $($gateway.operationalState). Wait for the current operation to finish and retry."
}

if ($Action -eq 'Stop') {
    Write-Warning "Stopping Application Gateway '$GatewayName' interrupts all gateway traffic until it is started again."
}
if (-not $PSCmdlet.ShouldProcess("$ResourceGroup/$GatewayName", "$Action Application Gateway")) {
    return $gateway
}

Write-Host "$Action operation for Application Gateway '$GatewayName' may take several minutes."
$null = Invoke-AzureCli -Arguments (@('network', 'application-gateway', $Action.ToLowerInvariant()) + $targetArguments + @('--output', 'none'))
$gateway = Invoke-AzureCli -Arguments $showArguments | ConvertFrom-Json
if ($gateway.operationalState -ne $expectedState) {
    throw "Application Gateway '$GatewayName' is $($gateway.operationalState) after $Action; expected $expectedState."
}
$gateway
