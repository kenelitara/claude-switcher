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

Export-ModuleMember -Function Get-Profiles, Get-ProfileDir, Test-ProfileExists
