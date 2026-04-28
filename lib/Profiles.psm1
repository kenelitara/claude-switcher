function Get-Profiles {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProfilesRoot)

    if (-not (Test-Path -LiteralPath $ProfilesRoot)) {
        New-Item -ItemType Directory -Force -Path $ProfilesRoot | Out-Null
        return @()
    }

    Get-ChildItem -LiteralPath $ProfilesRoot -Directory -Force |
        Where-Object { -not $_.Name.StartsWith('.') } |
        Sort-Object Name |
        ForEach-Object { $_.Name }
}

function Get-ProfileDir {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProfilesRoot,
        [Parameter(Mandatory)][string]$Name
    )
    Join-Path $ProfilesRoot $Name
}

function Test-ProfileExists {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProfilesRoot,
        [Parameter(Mandatory)][string]$Name
    )
    Test-Path -LiteralPath (Get-ProfileDir -ProfilesRoot $ProfilesRoot -Name $Name) -PathType Container
}

function Get-DefaultProfile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProfilesRoot)

    Import-Module (Join-Path $PSScriptRoot 'Schema.psm1') -Force
    $cfg = Read-SwitcherConfig -Path (Join-Path $ProfilesRoot '.switcher.json')
    return $cfg.default
}

function Set-DefaultProfile {
    [CmdletBinding(DefaultParameterSetName='Set')]
    param(
        [Parameter(Mandatory)][string]$ProfilesRoot,
        [Parameter(Mandatory, ParameterSetName='Set')][string]$Name,
        [Parameter(Mandatory, ParameterSetName='Reset')][switch]$Reset
    )

    Import-Module (Join-Path $PSScriptRoot 'Schema.psm1') -Force
    $path = Join-Path $ProfilesRoot '.switcher.json'

    if ($Reset) {
        Write-SwitcherConfig -Path $path -Default $null
        return
    }

    if (-not (Test-ProfileExists -ProfilesRoot $ProfilesRoot -Name $Name)) {
        throw "claude-switcher: account '$Name' is not configured. Run: claude-switch add $Name"
    }
    Write-SwitcherConfig -Path $path -Default $Name
}

function Find-ClaudeApplication {
    Get-Command claude -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
}

function Get-RealClaudeBinary {
    [CmdletBinding()] param()
    $cmd = Find-ClaudeApplication
    if (-not $cmd) {
        throw "claude-switcher: real 'claude' executable not found on PATH"
    }
    return $cmd.Source
}

Export-ModuleMember -Function Get-Profiles, Get-ProfileDir, Test-ProfileExists, Get-DefaultProfile, Set-DefaultProfile, Get-RealClaudeBinary
