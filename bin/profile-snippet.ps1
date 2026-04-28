$script:ClaudeSwitcherRoot = Split-Path -Parent $PSCommandPath

function global:claude {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$ClaudeArgs)
    $shim = Join-Path $script:ClaudeSwitcherRoot 'Invoke-ClaudeShim.ps1'
    & $shim @ClaudeArgs
}

function global:claude-switch {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$SwitchArgs)
    $cli = Join-Path $script:ClaudeSwitcherRoot 'claude-switch.ps1'
    & $cli @SwitchArgs
}
