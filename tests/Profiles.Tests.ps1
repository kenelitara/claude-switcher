BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\lib\Schema.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '..\lib\Profiles.psm1') -Force
}

Describe 'Get-Profiles / Get-ProfileDir / Test-ProfileExists' {
    BeforeEach {
        $script:root = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid())
        New-Item -ItemType Directory -Force -Path $script:root | Out-Null
    }
    AfterEach {
        if (Test-Path $script:root) { Remove-Item -Recurse -Force $script:root }
    }

    It 'returns an empty list when the profiles root has no subdirs' {
        @(Get-Profiles -ProfilesRoot $script:root).Count | Should -Be 0
    }

    It 'returns subdirectory names sorted, excluding dotfiles and the registry file' {
        New-Item -ItemType Directory -Path (Join-Path $script:root 'work') | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:root 'aaa-client') | Out-Null
        New-Item -ItemType File -Path (Join-Path $script:root '.switcher.json') -Value '{}' | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:root '.hidden') | Out-Null

        $names = @(Get-Profiles -ProfilesRoot $script:root)
        $names | Should -Be @('aaa-client', 'work')
    }

    It 'creates the profiles root if it is missing' {
        $missing = Join-Path $script:root 'nope'
        @(Get-Profiles -ProfilesRoot $missing).Count | Should -Be 0
        Test-Path $missing | Should -BeTrue
    }

    It 'Get-ProfileDir returns the joined path' {
        Get-ProfileDir -ProfilesRoot $script:root -Name 'work' |
            Should -Be (Join-Path $script:root 'work')
    }

    It 'Test-ProfileExists is true only when the dir exists' {
        Test-ProfileExists -ProfilesRoot $script:root -Name 'work' | Should -BeFalse
        New-Item -ItemType Directory -Path (Join-Path $script:root 'work') | Out-Null
        Test-ProfileExists -ProfilesRoot $script:root -Name 'work' | Should -BeTrue
    }
}
