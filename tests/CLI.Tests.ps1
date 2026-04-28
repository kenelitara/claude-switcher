BeforeAll {
    $script:cli = (Resolve-Path (Join-Path $PSScriptRoot '..\bin\claude-switch.ps1')).Path
    function Invoke-Cli {
        param([string]$Root, [Alias('Args')][string[]]$CliArgs, [string]$Cwd = (Get-Location).Path)
        $env:CLAUDE_SWITCHER_ROOT = $Root
        $out = & pwsh -NoProfile -File $script:cli @CliArgs 2>&1 | Out-String
        $code = $LASTEXITCODE
        Remove-Item env:CLAUDE_SWITCHER_ROOT -ErrorAction SilentlyContinue
        [PSCustomObject]@{ Output = $out; ExitCode = $code }
    }
}

Describe 'claude-switch help' {
    BeforeEach {
        $script:root = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid())
        New-Item -ItemType Directory -Force -Path $script:root | Out-Null
    }
    AfterEach { if (Test-Path $script:root) { Remove-Item -Recurse -Force $script:root } }

    It 'prints usage with no args' {
        (Invoke-Cli -Root $script:root -Args @()).Output | Should -Match 'Usage:'
    }
    It 'prints usage for help' {
        (Invoke-Cli -Root $script:root -Args @('help')).Output | Should -Match 'Usage:'
    }
    It 'exits 2 on unknown subcommand' {
        $r = Invoke-Cli -Root $script:root -Args @('frobnicate')
        $r.ExitCode | Should -Be 2
        $r.Output | Should -Match 'unknown subcommand'
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
        $out = (Invoke-Cli -Root $script:root -Args @('list')).Output
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
        $out = (Invoke-Cli -Root $script:root -Args @('where','work')).Output.Trim()
        $out | Should -Be (Join-Path $script:root 'work')
    }
    It 'errors on unknown profile' {
        $r = Invoke-Cli -Root $script:root -Args @('where','ghost')
        $r.Output | Should -Match "not configured"
        $r.ExitCode | Should -Not -Be 0
    }
}
