BeforeAll {
    $script:cli = (Resolve-Path (Join-Path $PSScriptRoot '..\bin\claude-switch.ps1')).Path
    function Invoke-Cli {
        param([string]$Root, [Alias('Args')][string[]]$CliArgs, [string]$Cwd = (Get-Location).Path)
        $env:CLAUDE_SWITCHER_ROOT = $Root
        $out = & pwsh -NoProfile -File $script:cli @CliArgs 2>&1 | Out-String
        Remove-Item env:CLAUDE_SWITCHER_ROOT -ErrorAction SilentlyContinue
        $out
    }
}

Describe 'claude-switch help' {
    BeforeEach {
        $script:root = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid())
        New-Item -ItemType Directory -Force -Path $script:root | Out-Null
    }
    AfterEach { if (Test-Path $script:root) { Remove-Item -Recurse -Force $script:root } }

    It 'prints usage with no args' {
        (Invoke-Cli -Root $script:root -Args @()) | Should -Match 'Usage:'
    }
    It 'prints usage for help' {
        (Invoke-Cli -Root $script:root -Args @('help')) | Should -Match 'Usage:'
    }
}

Describe 'claude-switch list' {
    BeforeEach {
        $script:root = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid())
        New-Item -ItemType Directory -Force -Path $script:root | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $script:root 'work') | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $script:root 'client') | Out-Null
    }
    AfterEach { if (Test-Path $script:root) { Remove-Item -Recurse -Force $script:root } }

    It 'lists personal first, then named profiles alphabetically' {
        $out = Invoke-Cli -Root $script:root -Args @('list')
        $out | Should -Match 'personal \(fallback\)'
        $out | Should -Match 'client'
        $out | Should -Match 'work'
        ($out.IndexOf('client') -lt $out.IndexOf('work')) | Should -BeTrue
    }
}

Describe 'claude-switch where' {
    BeforeEach {
        $script:root = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid())
        New-Item -ItemType Directory -Force -Path $script:root | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $script:root 'work') | Out-Null
    }
    AfterEach { if (Test-Path $script:root) { Remove-Item -Recurse -Force $script:root } }

    It 'prints the absolute profile dir' {
        $out = (Invoke-Cli -Root $script:root -Args @('where','work')).Trim()
        $out | Should -Be (Join-Path $script:root 'work')
    }
    It 'errors on unknown profile' {
        $out = Invoke-Cli -Root $script:root -Args @('where','ghost')
        $out | Should -Match "not configured"
    }
}
