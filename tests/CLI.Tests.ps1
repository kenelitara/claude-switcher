BeforeAll {
    $script:cli = (Resolve-Path (Join-Path $PSScriptRoot '..\bin\claude-switch.ps1')).Path
    function Invoke-Cli {
        param([string]$Root, [Alias('Args')][string[]]$CliArgs, [string]$Cwd = (Get-Location).Path)
        $env:CLAUDE_SWITCHER_ROOT = $Root
        Push-Location $Cwd
        try {
            $out = & pwsh -NoProfile -File $script:cli @CliArgs 2>&1 | Out-String
            $code = $LASTEXITCODE
        } finally {
            Pop-Location
        }
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

Describe 'claude-switch default' {
    BeforeEach {
        $script:root = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid())
        New-Item -ItemType Directory -Force -Path $script:root | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $script:root 'work') | Out-Null
    }
    AfterEach { if (Test-Path $script:root) { Remove-Item -Recurse -Force $script:root } }

    It 'sets the default profile' {
        Invoke-Cli -Root $script:root -Args @('default','work') | Out-Null
        $cfg = Get-Content -Raw (Join-Path $script:root '.switcher.json') | ConvertFrom-Json
        $cfg.default | Should -Be 'work'
    }
    It '--reset clears it' {
        Invoke-Cli -Root $script:root -Args @('default','work') | Out-Null
        Invoke-Cli -Root $script:root -Args @('default','--reset') | Out-Null
        $cfg = Get-Content -Raw (Join-Path $script:root '.switcher.json') | ConvertFrom-Json
        $cfg.default | Should -BeNullOrEmpty
    }
    It 'rejects unknown profile' {
        $out = Invoke-Cli -Root $script:root -Args @('default','ghost')
        $out.Output | Should -Match 'not configured'
    }
}

Describe 'claude-switch init' {
    BeforeEach {
        $script:root = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid())
        $script:cwd  = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid())
        New-Item -ItemType Directory -Force -Path $script:root, $script:cwd | Out-Null
    }
    AfterEach {
        if (Test-Path $script:root) { Remove-Item -Recurse -Force $script:root }
        if (Test-Path $script:cwd)  { Remove-Item -Recurse -Force $script:cwd }
    }

    It 'writes a claude-account.json into the cwd' {
        Invoke-Cli -Root $script:root -Args @('init','work') -Cwd $script:cwd | Out-Null
        $f = Join-Path $script:cwd 'claude-account.json'
        (Get-Content -Raw $f | ConvertFrom-Json).account | Should -Be 'work'
    }

    It 'refuses to overwrite without --force' {
        $f = Join-Path $script:cwd 'claude-account.json'
        Set-Content -LiteralPath $f -Encoding utf8NoBOM -Value '{ "account": "old" }'
        $out = Invoke-Cli -Root $script:root -Args @('init','new') -Cwd $script:cwd
        $out.Output | Should -Match 'already exists'
        (Get-Content -Raw $f | ConvertFrom-Json).account | Should -Be 'old'
    }
}

Describe 'claude-switch add' {
    BeforeEach {
        $script:root = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid())
        $script:fakeBin = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid())
        New-Item -ItemType Directory -Force -Path $script:root, $script:fakeBin | Out-Null

        # Fake claude.cmd: writes a marker file into $env:CLAUDE_CONFIG_DIR so we can
        # observe that the env var was set when the binary ran.
        $fake = Join-Path $script:fakeBin 'claude.cmd'
        Set-Content -LiteralPath $fake -Encoding ascii -Value @"
@echo off
echo fake-login > "%CLAUDE_CONFIG_DIR%\.credentials.json"
"@
        $script:savedPath = $env:PATH
        $env:PATH = "$script:fakeBin;$env:PATH"
    }
    AfterEach {
        $env:PATH = $script:savedPath
        if (Test-Path $script:root) { Remove-Item -Recurse -Force $script:root }
        if (Test-Path $script:fakeBin) { Remove-Item -Recurse -Force $script:fakeBin }
    }

    It 'creates the profile dir and runs claude with CLAUDE_CONFIG_DIR set' {
        Invoke-Cli -Root $script:root -Args @('add','work','--no-launch-prompt') | Out-Null
        $dir = Join-Path $script:root 'work'
        Test-Path $dir | Should -BeTrue
        Test-Path (Join-Path $dir '.credentials.json') | Should -BeTrue
    }

    It 'refuses to add an existing profile without --force' {
        New-Item -ItemType Directory -Path (Join-Path $script:root 'work') | Out-Null
        $out = Invoke-Cli -Root $script:root -Args @('add','work','--no-launch-prompt')
        $out.Output | Should -Match 'already exists'
    }
}

Describe 'claude-switch remove' {
    BeforeEach {
        $script:root = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid())
        New-Item -ItemType Directory -Force -Path $script:root | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $script:root 'work') | Out-Null
    }
    AfterEach { if (Test-Path $script:root) { Remove-Item -Recurse -Force $script:root } }

    It 'removes the profile when --force is passed' {
        Invoke-Cli -Root $script:root -Args @('remove','work','--force') | Out-Null
        Test-Path (Join-Path $script:root 'work') | Should -BeFalse
    }

    It 'refuses to remove an unknown profile' {
        $out = Invoke-Cli -Root $script:root -Args @('remove','ghost','--force')
        $out.Output | Should -Match 'not configured'
    }

    It 'refuses to remove the configured default without --force' {
        Invoke-Cli -Root $script:root -Args @('default','work') | Out-Null
        # No --force -> would prompt; the CLI must early-exit with an error in non-interactive contexts.
        $out = Invoke-Cli -Root $script:root -Args @('remove','work')
        $out.Output | Should -Match 'configured default'
    }
}
