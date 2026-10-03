function Split-ProfileFlag {
    [CmdletBinding()]
    param([string[]]$Arguments)

    $passThrough = [System.Collections.Generic.List[string]]::new()
    $profile     = $null
    $seenProfile = $false

    if ($null -ne $Arguments -and $Arguments.Count -gt 0) {
        $i    = 0
        $stop = $false
        while ($i -lt $Arguments.Count) {
            $tok = [string]$Arguments[$i]

            if ($stop) { $passThrough.Add($tok); $i++; continue }
            if ($tok -eq '--') { $stop = $true; $passThrough.Add($tok); $i++; continue }

            $value    = $null
            $consumed = 0
            if ($tok -match '^--profile=(.*)$') {
                $value    = [string]$Matches[1]
                $consumed = 1
            } elseif ($tok -eq '--profile') {
                if ($i + 1 -lt $Arguments.Count) {
                    $value    = [string]$Arguments[$i + 1]
                    $consumed = 2
                } else {
                    $consumed = 1
                }
            } else {
                $passThrough.Add($tok); $i++; continue
            }

            if ($seenProfile) {
                return [pscustomobject]@{ Args = $null; Profile = $null; Error = 'claude-switcher: --profile given more than once' }
            }
            if ([string]::IsNullOrWhiteSpace($value)) {
                return [pscustomobject]@{ Args = $null; Profile = $null; Error = 'claude-switcher: --profile requires a profile name' }
            }

            $seenProfile = $true
            $profile     = $value.Trim()
            $i += $consumed
        }
    }

    return [pscustomobject]@{ Args = $passThrough.ToArray(); Profile = $profile; Error = $null }
}

Export-ModuleMember -Function Split-ProfileFlag
