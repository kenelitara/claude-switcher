function Read-AccountConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding utf8 -ErrorAction Stop
    } catch {
        throw "claude-switcher: cannot read $($Path): $($_.Exception.Message)"
    }

    try {
        $obj = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "claude-switcher: $Path is not valid JSON: $($_.Exception.Message)"
    }

    if (-not $obj.PSObject.Properties.Match('account').Count -or
        $obj.account -isnot [string] -or
        [string]::IsNullOrWhiteSpace($obj.account)) {
        throw "claude-switcher: $Path must contain a non-empty `"account`" field"
    }

    return [pscustomobject]@{ account = $obj.account }
}

function Read-SwitcherConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ default = $null }
    }

    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding utf8 -ErrorAction Stop
    } catch {
        throw "claude-switcher: cannot read $($Path): $($_.Exception.Message)"
    }

    try {
        $obj = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "claude-switcher: $Path is not valid JSON: $($_.Exception.Message)"
    }

    $val = $null
    if ($obj.PSObject.Properties.Match('default').Count -and $obj.default -is [string] -and -not [string]::IsNullOrWhiteSpace($obj.default)) {
        $val = $obj.default
    }
    return [pscustomobject]@{ default = $val }
}

function Write-SwitcherConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [AllowNull()][string]$Default
    )

    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }

    $obj = [pscustomobject]@{ default = $Default }
    $json = $obj | ConvertTo-Json -Depth 4
    Set-Content -LiteralPath $Path -Value $json -Encoding utf8NoBOM
}

Export-ModuleMember -Function Read-AccountConfig, Read-SwitcherConfig, Write-SwitcherConfig
