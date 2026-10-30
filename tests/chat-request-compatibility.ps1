#requires -Version 7.2
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$script:checks = 0

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)

    if ($Actual -cne $Expected) {
        throw "$Message Expected '$Expected', got '$Actual'."
    }
    $script:checks++
}

$policy = [xml](Get-Content -LiteralPath (Join-Path $root 'infra\policies\chat-completions.xml') -Raw)
$expression = $policy.SelectSingleNode('/policies/inbound/set-body').InnerText
Assert-Equal $expression.StartsWith('@{') $true 'The production request rewrite must be a policy expression.'
Assert-Equal $expression.EndsWith('}') $true 'The production request rewrite must have a complete body.'
$bodyRead = 'context.Request.Body.As<JObject>(preserveContent: true)'
Assert-Equal $expression.Contains($bodyRead) $true 'The harness must replace only the APIM-specific body reader.'

# Compile the production expression, not a second implementation of the rewrite.
$body = $expression.Substring(2, $expression.Length - 3).
    Replace($bodyRead, 'JObject.Parse(input)').
    Replace('__DEFAULT_TEMPERATURE_MODELS_JSON__', '"temperature-model"').
    Replace('__NORMALIZE_OPENAI_TOKEN_LIMITS__', 'normalizeOpenAiTokenLimit')
$source = @"
using System;
using Newtonsoft.Json.Linq;

public static class ByokChatRequestCompatibility
{
    public static string Rewrite(string input, bool normalizeOpenAiTokenLimit)
    {
        $body
    }
}
"@
# PowerShell's loaded Newtonsoft assembly can target an older compatible System.Runtime.
Add-Type -TypeDefinition $source -ReferencedAssemblies ([Newtonsoft.Json.Linq.JObject].Assembly.Location) -CompilerOptions '/nowarn:1701'

function Invoke-Rewrite {
    param([hashtable]$Request, [bool]$OpenAi = $true)

    $json = $Request | ConvertTo-Json -Depth 16 -Compress
    [ByokChatRequestCompatibility]::Rewrite($json, $OpenAi) | ConvertFrom-Json -AsHashtable
}

$result = Invoke-Rewrite @{
    model = 'future-deployment-without-model-specific-settings'
    max_tokens = 1536
    messages = @(@{ role = 'user'; content = 'Hello' })
    metadata = @{ label = 'preserve-me' }
}
Assert-Equal $result.Contains('max_tokens') $false 'Do not forward the deprecated limit to the Foundry OpenAI contract.'
Assert-Equal $result.max_completion_tokens 1536 'Preserve the requested output budget exactly.'
Assert-Equal $result.model 'future-deployment-without-model-specific-settings' 'Normalization must not depend on a model-name list.'
Assert-Equal $result.messages[0].content 'Hello' 'Preserve messages.'
Assert-Equal $result.metadata.label 'preserve-me' 'Preserve unrelated request fields.'

$result = Invoke-Rewrite @{ model = 'another-alias'; max_completion_tokens = 73 }
Assert-Equal $result.max_completion_tokens 73 'Canonical-only requests must be unchanged.'
Assert-Equal $result.Contains('max_tokens') $false 'Do not introduce a deprecated limit.'

$result = Invoke-Rewrite @{ model = 'any-alias'; max_tokens = 4096; max_completion_tokens = 128 }
Assert-Equal $result.max_completion_tokens 128 'An explicitly supplied canonical limit takes precedence; never increase it.'
Assert-Equal $result.Contains('max_tokens') $false 'Remove the deprecated duplicate.'

$result = Invoke-Rewrite @{ model = 'any-alias'; max_tokens = 64; max_completion_tokens = $null }
Assert-Equal $result.max_completion_tokens 64 'A null canonical limit must not suppress the legacy value.'

$result = Invoke-Rewrite @{ model = 'any-alias'; messages = @() }
Assert-Equal $result.Contains('max_tokens') $false 'A missing limit must remain missing.'
Assert-Equal $result.Contains('max_completion_tokens') $false 'Do not invent a default output budget.'

foreach ($limit in @(0, -1)) {
    $result = Invoke-Rewrite @{ model = 'any-alias'; max_tokens = $limit }
    Assert-Equal $result.max_completion_tokens $limit 'Do not silently clamp invalid values; retain upstream validation.'
}

$result = Invoke-Rewrite -OpenAi $false -Request @{ model = 'legacy-provider-alias'; max_tokens = 65 }
Assert-Equal $result.max_tokens 65 'Retain the legacy contract for alternate managed-compute backends.'
Assert-Equal $result.Contains('max_completion_tokens') $false 'Do not send unsupported canonical fields to legacy backends.'

$result = Invoke-Rewrite @{ model = 'TEMPERATURE-MODEL'; temperature = 0.1 }
Assert-Equal $result.temperature 1 'Preserve existing case-insensitive temperature normalization.'
$result = Invoke-Rewrite @{ model = 'another-model'; temperature = 0.35 }
Assert-Equal $result.temperature 0.35 'Do not change temperatures globally.'

$result = Invoke-Rewrite @{
    model = 'any-alias'
    tools = @(
        @{ type = 'function'; function = @{ name = 'missing-strict' } }
        @{ type = 'function'; function = @{ name = 'explicit-strict'; strict = $true } }
        @{ type = 'function'; function = @{ name = 'null-strict'; strict = $null } }
    )
}
Assert-Equal $result.tools[0].function.strict $false 'Preserve non-strict defaults for function tools.'
Assert-Equal $result.tools[1].function.strict $true 'Preserve explicit strict function tools.'
Assert-Equal $result.tools[2].function.strict $false 'Preserve null strict handling.'

Write-Output "PASS: $script:checks offline chat-request compatibility checks. Executed the production policy expression; no Azure resources were accessed."
