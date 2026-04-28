#!/usr/bin/env pwsh
[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'

$profilePath = $PROFILE.CurrentUserAllHosts
if (-not (Test-Path -LiteralPath $profilePath)) {
    Write-Output "claude-switcher: nothing to do — $profilePath does not exist."
    return
}

$beginMarker = '# >>> claude-switcher >>>'
$endMarker   = '# <<< claude-switcher <<<'
$pattern = "(?ms)\r?\n?$([regex]::Escape($beginMarker)).*?$([regex]::Escape($endMarker))\r?\n?"
$existing = Get-Content -Raw -LiteralPath $profilePath
if ($existing -notmatch $pattern) {
    Write-Output "claude-switcher: marker block not found in $profilePath — nothing to remove."
    return
}
$updated = [regex]::Replace($existing, $pattern, "`r`n")
Set-Content -LiteralPath $profilePath -Value $updated.TrimEnd() -Encoding utf8NoBOM

Write-Output "claude-switcher: removed marker block from $profilePath."
Write-Output "Note: profile directories under $($env:USERPROFILE)\.claude-accounts\ were not deleted."
Write-Output "      To wipe credentials, run:  Remove-Item -Recurse -Force '$env:USERPROFILE\.claude-accounts'"
