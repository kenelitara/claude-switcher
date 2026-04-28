Import-Module (Join-Path $PSScriptRoot 'Schema.psm1')
Import-Module (Join-Path $PSScriptRoot 'Profiles.psm1')

function Resolve-ProfileForCwd {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Cwd,
        [Parameter(Mandatory)][string]$ProfilesRoot,
        [string]$PresetConfigDir
    )

    if (-not [string]::IsNullOrWhiteSpace($PresetConfigDir)) {
        return [pscustomobject]@{
            Source = 'env-bypass'
            ProfileDir = $null
            Reason = "CLAUDE_CONFIG_DIR already set to $PresetConfigDir"
        }
    }

    $projectFile = Join-Path $Cwd 'claude-account.json'
    if (Test-Path -LiteralPath $projectFile) {
        $cfg = Read-AccountConfig -Path $projectFile
        if (-not (Test-ProfileExists -ProfilesRoot $ProfilesRoot -Name $cfg.account)) {
            throw "claude-switcher: account '$($cfg.account)' is not configured. Run: claude-switch add $($cfg.account)"
        }
        return [pscustomobject]@{
            Source = 'project'
            ProfileDir = Get-ProfileDir -ProfilesRoot $ProfilesRoot -Name $cfg.account
            Reason = "$($cfg.account) — from .\claude-account.json"
        }
    }

    $default = Get-DefaultProfile -ProfilesRoot $ProfilesRoot
    if ($default -and (Test-ProfileExists -ProfilesRoot $ProfilesRoot -Name $default)) {
        return [pscustomobject]@{
            Source = 'default'
            ProfileDir = Get-ProfileDir -ProfilesRoot $ProfilesRoot -Name $default
            Reason = "$default — configured default override"
        }
    }

    return [pscustomobject]@{
        Source = 'personal'
        ProfileDir = $null
        Reason = 'personal (~\.claude) — no claude-account.json'
    }
}

Export-ModuleMember -Function Resolve-ProfileForCwd
