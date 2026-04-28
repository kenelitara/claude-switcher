#!/usr/bin/env pwsh
[CmdletBinding()]
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$RestArgs)

$ErrorActionPreference = 'Stop'

$root = $env:CLAUDE_SWITCHER_ROOT
if ([string]::IsNullOrWhiteSpace($root)) {
    $root = Join-Path $env:USERPROFILE '.claude-accounts'
}
if (-not (Test-Path -LiteralPath $root)) {
    New-Item -ItemType Directory -Force -Path $root | Out-Null
}

$libRoot = Resolve-Path (Join-Path $PSScriptRoot '..\lib')
Import-Module (Join-Path $libRoot 'Schema.psm1')
Import-Module (Join-Path $libRoot 'Profiles.psm1')
Import-Module (Join-Path $libRoot 'Resolve.psm1')

function Show-Usage {
@'
Usage: claude-switch <command> [args]

Commands:
  add <name>         Create a profile and launch claude so you can /login.
  list               List all profiles, marking personal (fallback) and current.
  remove <name>      Delete a profile directory (asks for confirmation).
  current            Print which profile resolves in the current directory.
  default <name>     Override the fallback (instead of personal).
  default --reset    Restore personal as the fallback.
  where <name>       Print the absolute path of a profile dir.
  init [name]        Write a claude-account.json into the current directory.
  help               Show this message.
'@
}

if (-not $RestArgs -or $RestArgs.Count -eq 0 -or $RestArgs[0] -in @('help','-h','--help')) {
    Show-Usage
    exit 0
}

$cmd  = $RestArgs[0]
[string[]]$rest = if ($RestArgs.Count -gt 1) { $RestArgs[1..($RestArgs.Count - 1)] } else { @() }

switch ($cmd) {
    'list' {
        $profiles = Get-Profiles -ProfilesRoot $root
        $default  = Get-DefaultProfile -ProfilesRoot $root
        $resolved = Resolve-ProfileForCwd -Cwd (Get-Location).Path -ProfilesRoot $root -PresetConfigDir $env:CLAUDE_CONFIG_DIR

        $personalMarker = ''
        if ($resolved.Source -eq 'personal') { $personalMarker = ' [current]' }
        Write-Output ("personal (fallback)" + $personalMarker)

        foreach ($p in $profiles) {
            $marks = @()
            if ($p -eq $default) { $marks += 'default' }
            if ($resolved.Source -in @('project','default') -and
                $resolved.ProfileDir -eq (Get-ProfileDir -ProfilesRoot $root -Name $p)) {
                $marks += 'current'
            }
            $tag = if ($marks) { " [" + ($marks -join ', ') + "]" } else { '' }
            Write-Output ("  $p$tag")
        }
        exit 0
    }

    'where' {
        if ($rest.Count -ne 1) { throw "claude-switcher: 'where' requires a single profile name" }
        $name = $rest[0]
        if (-not (Test-ProfileExists -ProfilesRoot $root -Name $name)) {
            throw "claude-switcher: account '$name' is not configured"
        }
        Write-Output (Get-ProfileDir -ProfilesRoot $root -Name $name)
        exit 0
    }

    'current' {
        $r = Resolve-ProfileForCwd -Cwd (Get-Location).Path -ProfilesRoot $root -PresetConfigDir $env:CLAUDE_CONFIG_DIR
        Write-Output $r.Reason
        exit 0
    }

    'default' {
        if (-not $rest -or $rest.Count -lt 1) { throw "claude-switcher: 'default' requires <name> or --reset" }
        if ($rest[0] -eq '--reset') {
            Set-DefaultProfile -ProfilesRoot $root -Reset
            Write-Output 'claude-switcher: default reset to personal (~\.claude)'
        } else {
            Set-DefaultProfile -ProfilesRoot $root -Name $rest[0]
            Write-Output "claude-switcher: default set to '$($rest[0])'"
        }
        exit 0
    }

    'init' {
        if (-not $rest -or $rest.Count -lt 1) { throw "claude-switcher: 'init' requires <name>" }
        $force = $rest -contains '--force'
        $name  = $rest | Where-Object { $_ -ne '--force' } | Select-Object -First 1
        if (-not $name) { throw "claude-switcher: 'init' requires <name>" }

        $target = Join-Path (Get-Location).Path 'claude-account.json'
        if ((Test-Path -LiteralPath $target) -and -not $force) {
            throw "claude-switcher: $target already exists (use --force to overwrite)"
        }
        $obj  = [pscustomobject]@{ account = $name }
        $json = $obj | ConvertTo-Json -Depth 4
        Set-Content -LiteralPath $target -Value $json -Encoding utf8NoBOM
        Write-Output "claude-switcher: wrote $target"
        exit 0
    }

    'add' {
        if (-not $rest) { throw "claude-switcher: 'add' requires <name>" }
        $skipPrompt = $rest -contains '--no-launch-prompt'
        $force      = $rest -contains '--force'
        $name       = $rest | Where-Object { $_ -notlike '--*' } | Select-Object -First 1
        if (-not $name) { throw "claude-switcher: 'add' requires <name>" }

        $dir = Get-ProfileDir -ProfilesRoot $root -Name $name
        if ((Test-Path -LiteralPath $dir) -and -not $force) {
            throw "claude-switcher: profile '$name' already exists at $dir (use --force to reuse)"
        }
        New-Item -ItemType Directory -Force -Path $dir | Out-Null

        if (-not $skipPrompt) {
            Write-Output "claude-switcher: profile '$name' created at $dir."
            Write-Output "Launching 'claude' so you can /login. Press any key to continue, Ctrl+C to skip."
            $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        }

        $real = Get-RealClaudeBinary
        $env:CLAUDE_CONFIG_DIR = $dir
        try {
            & $real
        } finally {
            Remove-Item env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue
        }
        exit 0
    }

    'remove' {
        if (-not $rest) { throw "claude-switcher: 'remove' requires <name>" }
        $force = $rest -contains '--force'
        $name  = $rest | Where-Object { $_ -notlike '--*' } | Select-Object -First 1
        if (-not $name) { throw "claude-switcher: 'remove' requires <name>" }
        if (-not (Test-ProfileExists -ProfilesRoot $root -Name $name)) {
            throw "claude-switcher: account '$name' is not configured"
        }
        $default = Get-DefaultProfile -ProfilesRoot $root
        if ($default -eq $name -and -not $force) {
            throw "claude-switcher: '$name' is the configured default. Run 'claude-switch default --reset' first, or pass --force"
        }
        if (-not $force) {
            Write-Output "claude-switcher: about to delete $(Get-ProfileDir -ProfilesRoot $root -Name $name). Press 'y' to confirm."
            $key = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
            if ($key.Character -ne 'y' -and $key.Character -ne 'Y') {
                Write-Output 'cancelled'
                exit 1
            }
        }
        Remove-Item -Recurse -Force (Get-ProfileDir -ProfilesRoot $root -Name $name)
        if ($default -eq $name) { Set-DefaultProfile -ProfilesRoot $root -Reset }
        Write-Output "claude-switcher: removed '$name'"
        exit 0
    }

    default {
        [Console]::Error.WriteLine("claude-switcher: unknown subcommand '$cmd'. Run 'claude-switch help'.")
        exit 2
    }
}
