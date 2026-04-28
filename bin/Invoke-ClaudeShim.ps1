#!/usr/bin/env pwsh
[CmdletBinding()]
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$ClaudeArgs)

$ErrorActionPreference = 'Stop'

$root = $env:CLAUDE_SWITCHER_ROOT
if ([string]::IsNullOrWhiteSpace($root)) {
    $root = Join-Path $env:USERPROFILE '.claude-accounts'
}

$libRoot = Resolve-Path (Join-Path $PSScriptRoot '..\lib')
Import-Module (Join-Path $libRoot 'Schema.psm1')
Import-Module (Join-Path $libRoot 'Profiles.psm1')
Import-Module (Join-Path $libRoot 'Resolve.psm1')

try {
    $decision = Resolve-ProfileForCwd `
        -Cwd (Get-Location).Path `
        -ProfilesRoot $root `
        -PresetConfigDir $env:CLAUDE_CONFIG_DIR
} catch {
    Write-Error $_.Exception.Message
    exit 1
}

if ($decision.Source -eq 'env-bypass') {
    [Console]::Error.WriteLine("claude-switcher: $($decision.Reason), bypassing")
} elseif ($decision.ProfileDir) {
    $env:CLAUDE_CONFIG_DIR = $decision.ProfileDir
}

$real = Get-RealClaudeBinary
& $real @ClaudeArgs
exit $LASTEXITCODE
