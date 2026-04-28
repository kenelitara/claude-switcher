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

Describe 'Default profile get/set' {
    BeforeEach {
        $script:root = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid())
        New-Item -ItemType Directory -Force -Path $script:root | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $script:root 'work') | Out-Null
    }
    AfterEach {
        if (Test-Path $script:root) { Remove-Item -Recurse -Force $script:root }
    }

    It 'returns null when no .switcher.json exists' {
        Get-DefaultProfile -ProfilesRoot $script:root | Should -BeNullOrEmpty
    }

    It 'persists and reads back a default name' {
        Set-DefaultProfile -ProfilesRoot $script:root -Name 'work'
        Get-DefaultProfile -ProfilesRoot $script:root | Should -Be 'work'
    }

    It 'refuses to set a default that does not exist' {
        { Set-DefaultProfile -ProfilesRoot $script:root -Name 'ghost' } |
            Should -Throw '*not configured*'
    }

    It 'allows clearing the default with -Reset' {
        Set-DefaultProfile -ProfilesRoot $script:root -Name 'work'
        Set-DefaultProfile -ProfilesRoot $script:root -Reset
        Get-DefaultProfile -ProfilesRoot $script:root | Should -BeNullOrEmpty
    }
}

Describe 'Get-RealClaudeBinary' {
    It 'returns a path to a real claude executable when one exists on PATH' {
        Mock -ModuleName Profiles Find-ClaudeApplication {
            [pscustomobject]@{ Source = 'C:\fake\claude.cmd' }
        }
        Get-RealClaudeBinary | Should -Be 'C:\fake\claude.cmd'
    }

    It 'throws a descriptive error when no claude is on PATH' {
        Mock -ModuleName Profiles Find-ClaudeApplication { $null }
        { Get-RealClaudeBinary } | Should -Throw "*real 'claude' executable not found on PATH*"
    }
}
