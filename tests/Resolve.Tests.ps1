BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\lib\Schema.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '..\lib\Profiles.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '..\lib\Resolve.psm1') -Force
}

Describe 'Resolve-ProfileForCwd' {
    BeforeEach {
        $script:root = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid())
        $script:cwd  = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid())
        New-Item -ItemType Directory -Force -Path $script:root, $script:cwd | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $script:root 'work') | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $script:root 'client') | Out-Null
    }
    AfterEach {
        if (Test-Path $script:root) { Remove-Item -Recurse -Force $script:root }
        if (Test-Path $script:cwd)  { Remove-Item -Recurse -Force $script:cwd }
    }

    It 'returns env-bypass when CLAUDE_CONFIG_DIR is preset' {
        $r = Resolve-ProfileForCwd -Cwd $script:cwd -ProfilesRoot $script:root -PresetConfigDir 'C:\already'
        $r.Source | Should -Be 'env-bypass'
        $r.ProfileDir | Should -BeNullOrEmpty
    }

    It 'returns project when claude-account.json picks a known profile' {
        Set-Content -LiteralPath (Join-Path $script:cwd 'claude-account.json') `
                    -Encoding utf8NoBOM -Value '{ "account": "work" }'
        $r = Resolve-ProfileForCwd -Cwd $script:cwd -ProfilesRoot $script:root
        $r.Source | Should -Be 'project'
        $r.ProfileDir | Should -Be (Join-Path $script:root 'work')
        $r.Reason | Should -Match 'claude-account.json'
    }

    It 'throws when claude-account.json names an unknown profile' {
        Set-Content -LiteralPath (Join-Path $script:cwd 'claude-account.json') `
                    -Encoding utf8NoBOM -Value '{ "account": "ghost" }'
        { Resolve-ProfileForCwd -Cwd $script:cwd -ProfilesRoot $script:root } |
            Should -Throw "*account 'ghost' is not configured*"
    }

    It 'throws when claude-account.json is malformed' {
        Set-Content -LiteralPath (Join-Path $script:cwd 'claude-account.json') `
                    -Encoding utf8NoBOM -Value '{ broken'
        { Resolve-ProfileForCwd -Cwd $script:cwd -ProfilesRoot $script:root } |
            Should -Throw '*not valid JSON*'
    }

    It 'returns personal when no claude-account.json and no default' {
        $r = Resolve-ProfileForCwd -Cwd $script:cwd -ProfilesRoot $script:root
        $r.Source | Should -Be 'personal'
        $r.ProfileDir | Should -BeNullOrEmpty
    }

    It 'returns default when no claude-account.json but a default is set' {
        Set-DefaultProfile -ProfilesRoot $script:root -Name 'client'
        $r = Resolve-ProfileForCwd -Cwd $script:cwd -ProfilesRoot $script:root
        $r.Source | Should -Be 'default'
        $r.ProfileDir | Should -Be (Join-Path $script:root 'client')
    }

    It 'falls back to personal when configured default points at a missing dir' {
        Set-DefaultProfile -ProfilesRoot $script:root -Name 'client'
        Remove-Item -Recurse -Force (Join-Path $script:root 'client')
        $r = Resolve-ProfileForCwd -Cwd $script:cwd -ProfilesRoot $script:root
        $r.Source | Should -Be 'personal'
    }
}

Describe 'Resolve-ProfileForCwd with -ExplicitProfile' {
    BeforeEach {
        $script:root = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid())
        $script:cwd  = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid())
        New-Item -ItemType Directory -Force -Path $script:root, $script:cwd | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $script:root 'work') | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $script:root 'client') | Out-Null
    }
    AfterEach {
        if (Test-Path $script:root) { Remove-Item -Recurse -Force $script:root }
        if (Test-Path $script:cwd)  { Remove-Item -Recurse -Force $script:cwd }
    }

    It 'returns explicit for a known profile' {
        $r = Resolve-ProfileForCwd -Cwd $script:cwd -ProfilesRoot $script:root -ExplicitProfile 'client'
        $r.Source     | Should -Be 'explicit'
        $r.ProfileDir | Should -Be (Join-Path $script:root 'client')
        $r.Reason     | Should -Match '--profile'
    }

    It 'throws for an unknown explicit profile' {
        { Resolve-ProfileForCwd -Cwd $script:cwd -ProfilesRoot $script:root -ExplicitProfile 'ghost' } |
            Should -Throw "*account 'ghost' is not configured*"
    }

    It 'treats "personal" and "none" as force-personal sentinels' {
        foreach ($sentinel in @('personal','none')) {
            $r = Resolve-ProfileForCwd -Cwd $script:cwd -ProfilesRoot $script:root -ExplicitProfile $sentinel
            $r.Source     | Should -Be 'explicit-personal'
            $r.ProfileDir | Should -BeNullOrEmpty
        }
    }

    It 'beats a preset CLAUDE_CONFIG_DIR' {
        $r = Resolve-ProfileForCwd -Cwd $script:cwd -ProfilesRoot $script:root `
                -PresetConfigDir 'C:\already' -ExplicitProfile 'work'
        $r.Source     | Should -Be 'explicit'
        $r.ProfileDir | Should -Be (Join-Path $script:root 'work')
    }

    It 'beats a claude-account.json naming another profile' {
        Set-Content -LiteralPath (Join-Path $script:cwd 'claude-account.json') `
                    -Encoding utf8NoBOM -Value '{ "account": "client" }'
        $r = Resolve-ProfileForCwd -Cwd $script:cwd -ProfilesRoot $script:root -ExplicitProfile 'work'
        $r.Source     | Should -Be 'explicit'
        $r.ProfileDir | Should -Be (Join-Path $script:root 'work')
    }

    It 'still allows forcing personal past a project file' {
        Set-Content -LiteralPath (Join-Path $script:cwd 'claude-account.json') `
                    -Encoding utf8NoBOM -Value '{ "account": "work" }'
        $r = Resolve-ProfileForCwd -Cwd $script:cwd -ProfilesRoot $script:root -ExplicitProfile 'personal'
        $r.Source | Should -Be 'explicit-personal'
    }

    It 'beats a configured default' {
        Set-DefaultProfile -ProfilesRoot $script:root -Name 'client'
        $r = Resolve-ProfileForCwd -Cwd $script:cwd -ProfilesRoot $script:root -ExplicitProfile 'work'
        $r.Source     | Should -Be 'explicit'
        $r.ProfileDir | Should -Be (Join-Path $script:root 'work')
    }

    It 'forces personal past a preset CLAUDE_CONFIG_DIR' {
        $r = Resolve-ProfileForCwd -Cwd $script:cwd -ProfilesRoot $script:root `
                -PresetConfigDir 'C:\already' -ExplicitProfile 'personal'
        $r.Source | Should -Be 'explicit-personal'
    }
}
