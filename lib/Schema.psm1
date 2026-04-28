function Read-AccountConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding utf8
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

Export-ModuleMember -Function Read-AccountConfig
