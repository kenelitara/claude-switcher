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
Import-Module (Join-Path $libRoot 'Args.psm1')

$split = Split-ProfileFlag -Arguments $ClaudeArgs
if ($split.Error) {
    [Console]::Error.WriteLine($split.Error)
    exit 1
}

try {
    $decision = Resolve-ProfileForCwd `
        -Cwd (Get-Location).Path `
        -ProfilesRoot $root `
        -PresetConfigDir $env:CLAUDE_CONFIG_DIR `
        -ExplicitProfile $split.Profile
} catch {
    Write-Error $_.Exception.Message
    exit 1
}

switch ($decision.Source) {
    'env-bypass' {
        [Console]::Error.WriteLine("claude-switcher: $($decision.Reason), bypassing")
    }
    'explicit-personal' {
        Remove-Item env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue
    }
    'explicit' {
        $env:CLAUDE_CONFIG_DIR = $decision.ProfileDir
    }
    default {
        if ($decision.ProfileDir) { $env:CLAUDE_CONFIG_DIR = $decision.ProfileDir }
    }
}

$real = Get-RealClaudeBinary
& $real @($split.Args)
exit $LASTEXITCODE
