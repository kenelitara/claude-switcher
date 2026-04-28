#!/usr/bin/env pwsh
[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "claude-switcher requires PowerShell 7 or newer (current: $($PSVersionTable.PSVersion))"
}

$repoRoot = $PSScriptRoot
$snippet  = Join-Path $repoRoot 'bin\profile-snippet.ps1'
if (-not (Test-Path -LiteralPath $snippet)) {
    throw "claude-switcher: $snippet missing — is the repo intact?"
}

$profilePath = $PROFILE.CurrentUserAllHosts
$profileDir  = Split-Path -Parent $profilePath
if (-not (Test-Path -LiteralPath $profileDir)) {
    New-Item -ItemType Directory -Force -Path $profileDir | Out-Null
}
if (-not (Test-Path -LiteralPath $profilePath)) {
    Set-Content -LiteralPath $profilePath -Value '' -Encoding utf8NoBOM
}

$beginMarker = '# >>> claude-switcher >>>'
$endMarker   = '# <<< claude-switcher <<<'
$block = @"
$beginMarker
. '$snippet'
$endMarker
"@

$existing = Get-Content -Raw -LiteralPath $profilePath
$pattern  = "(?ms)$([regex]::Escape($beginMarker)).*?$([regex]::Escape($endMarker))"
if ($existing -match $pattern) {
    $updated = [regex]::Replace($existing, $pattern, $block)
} else {
    $updated = $existing.TrimEnd() + "`r`n`r`n" + $block + "`r`n"
}
Set-Content -LiteralPath $profilePath -Value $updated -Encoding utf8NoBOM

$accountsRoot = Join-Path $env:USERPROFILE '.claude-accounts'
New-Item -ItemType Directory -Force -Path $accountsRoot | Out-Null

Write-Output ''
Write-Output "claude-switcher installed to: $profilePath"
Write-Output 'Next steps:'
Write-Output '  1. Reload your profile in any open terminal:  . $PROFILE'
Write-Output '  2. Add a non-personal account:                claude-switch add work'
Write-Output '  3. Inside a project folder:                   claude-switch init work'
