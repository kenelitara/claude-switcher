BeforeAll {
    $script:shim = (Resolve-Path (Join-Path $PSScriptRoot '..\bin\Invoke-ClaudeShim.ps1')).Path
}

Describe 'Invoke-ClaudeShim' {
    BeforeEach {
        $script:root = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid())
        $script:cwd  = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid())
        $script:fakeBin = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid())
        New-Item -ItemType Directory -Force -Path $script:root, $script:cwd, $script:fakeBin | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $script:root 'work') | Out-Null

        $script:probe = Join-Path ([System.IO.Path]::GetTempPath()) "shim-probe-$([guid]::NewGuid()).txt"
        $fake = Join-Path $script:fakeBin 'claude.cmd'
        # Fake claude writes "<arg1>|<arg2>|...|<env>" to a probe file then exits 0.
        Set-Content -LiteralPath $fake -Encoding ascii -Value @"
@echo off
echo args=%*^|env=%CLAUDE_CONFIG_DIR% > "$($script:probe)"
"@
        $script:savedPath = $env:PATH
        $env:PATH = "$script:fakeBin;$env:PATH"
    }
    AfterEach {
        $env:PATH = $script:savedPath
        Remove-Item env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue
        foreach ($p in @($script:root, $script:cwd, $script:fakeBin, $script:probe)) {
            if ($p -and (Test-Path $p)) { Remove-Item -Recurse -Force $p }
        }
    }

    It 'routes to a project-named profile and forwards args' {
        Set-Content -LiteralPath (Join-Path $script:cwd 'claude-account.json') `
                    -Encoding utf8NoBOM -Value '{ "account": "work" }'
        $env:CLAUDE_SWITCHER_ROOT = $script:root
        Push-Location $script:cwd
        try {
            & pwsh -NoProfile -File $script:shim hello world
        } finally {
            Pop-Location
            Remove-Item env:CLAUDE_SWITCHER_ROOT -ErrorAction SilentlyContinue
        }
        $line = (Get-Content -Raw $script:probe).Trim()
        $line | Should -Match 'args=hello world'
        $line | Should -Match ([regex]::Escape("env=$(Join-Path $script:root 'work')"))
    }

    It 'falls back to personal (no env var) when no claude-account.json' {
        $env:CLAUDE_SWITCHER_ROOT = $script:root
        Push-Location $script:cwd
        try {
            & pwsh -NoProfile -File $script:shim
        } finally {
            Pop-Location
            Remove-Item env:CLAUDE_SWITCHER_ROOT -ErrorAction SilentlyContinue
        }
        $line = (Get-Content -Raw $script:probe).Trim()
        $line | Should -Match 'env=$'  # CLAUDE_CONFIG_DIR was empty when the fake ran
    }

    It 'errors out when the project file names an unknown profile' {
        Set-Content -LiteralPath (Join-Path $script:cwd 'claude-account.json') `
                    -Encoding utf8NoBOM -Value '{ "account": "ghost" }'
        $env:CLAUDE_SWITCHER_ROOT = $script:root
        Push-Location $script:cwd
        try {
            $out = & pwsh -NoProfile -File $script:shim 2>&1 | Out-String
            $out | Should -Match "account 'ghost' is not configured"
        } finally {
            Pop-Location
            Remove-Item env:CLAUDE_SWITCHER_ROOT -ErrorAction SilentlyContinue
        }
    }

    It 'bypasses routing when CLAUDE_CONFIG_DIR is preset' {
        Set-Content -LiteralPath (Join-Path $script:cwd 'claude-account.json') `
                    -Encoding utf8NoBOM -Value '{ "account": "work" }'
        $env:CLAUDE_SWITCHER_ROOT = $script:root
        $env:CLAUDE_CONFIG_DIR = 'C:\custom'
        Push-Location $script:cwd
        try {
            & pwsh -NoProfile -File $script:shim 2>&1 | Out-Null
        } finally {
            Pop-Location
            Remove-Item env:CLAUDE_SWITCHER_ROOT -ErrorAction SilentlyContinue
            Remove-Item env:CLAUDE_CONFIG_DIR    -ErrorAction SilentlyContinue
        }
        $line = (Get-Content -Raw $script:probe).Trim()
        $line | Should -Match ([regex]::Escape('env=C:\custom'))
    }

    It 'routes --profile to the named profile and strips the flag' {
        $env:CLAUDE_SWITCHER_ROOT = $script:root
        Push-Location $script:cwd
        try {
            & pwsh -NoProfile -File $script:shim --profile work --resume
        } finally {
            Pop-Location
            Remove-Item env:CLAUDE_SWITCHER_ROOT -ErrorAction SilentlyContinue
        }
        $line = (Get-Content -Raw $script:probe).Trim()
        $line | Should -Match 'args=--resume'
        $line | Should -Not -Match 'profile'
        $line | Should -Match ([regex]::Escape("env=$(Join-Path $script:root 'work')"))
    }

    It 'forces personal with --profile personal even when a project file exists' {
        Set-Content -LiteralPath (Join-Path $script:cwd 'claude-account.json') `
                    -Encoding utf8NoBOM -Value '{ "account": "work" }'
        $env:CLAUDE_SWITCHER_ROOT = $script:root
        $env:CLAUDE_CONFIG_DIR = 'C:\custom'
        Push-Location $script:cwd
        try {
            & pwsh -NoProfile -File $script:shim --profile personal
        } finally {
            Pop-Location
            Remove-Item env:CLAUDE_SWITCHER_ROOT -ErrorAction SilentlyContinue
            Remove-Item env:CLAUDE_CONFIG_DIR    -ErrorAction SilentlyContinue
        }
        $line = (Get-Content -Raw $script:probe).Trim()
        $line | Should -Match 'env=$'
    }

    It 'lets --profile override a preset CLAUDE_CONFIG_DIR' {
        $env:CLAUDE_SWITCHER_ROOT = $script:root
        $env:CLAUDE_CONFIG_DIR = 'C:\custom'
        Push-Location $script:cwd
        try {
            & pwsh -NoProfile -File $script:shim --profile work
        } finally {
            Pop-Location
            Remove-Item env:CLAUDE_SWITCHER_ROOT -ErrorAction SilentlyContinue
            Remove-Item env:CLAUDE_CONFIG_DIR    -ErrorAction SilentlyContinue
        }
        $line = (Get-Content -Raw $script:probe).Trim()
        $line | Should -Match ([regex]::Escape("env=$(Join-Path $script:root 'work')"))
    }

    It 'errors on an unknown --profile' {
        $env:CLAUDE_SWITCHER_ROOT = $script:root
        Push-Location $script:cwd
        try {
            $out = & pwsh -NoProfile -File $script:shim --profile ghost 2>&1 | Out-String
            $LASTEXITCODE | Should -Not -Be 0
            $out | Should -Match "account 'ghost' is not configured"
        } finally {
            Pop-Location
            Remove-Item env:CLAUDE_SWITCHER_ROOT -ErrorAction SilentlyContinue
        }
    }

    It 'errors when --profile has no value' {
        $env:CLAUDE_SWITCHER_ROOT = $script:root
        Push-Location $script:cwd
        try {
            $out = & pwsh -NoProfile -File $script:shim --profile 2>&1 | Out-String
            $LASTEXITCODE | Should -Not -Be 0
            $out | Should -Match 'requires a profile name'
        } finally {
            Pop-Location
            Remove-Item env:CLAUDE_SWITCHER_ROOT -ErrorAction SilentlyContinue
        }
    }

    It 'drives --profile through the claude wrapper function' {
        $env:CLAUDE_SWITCHER_ROOT = $script:root
        Push-Location $script:cwd
        try {
            $snippet = Join-Path (Split-Path -Parent $script:shim) 'profile-snippet.ps1'
            & pwsh -NoProfile -Command ". '$snippet'; claude --profile work --resume"
        } finally {
            Pop-Location
            Remove-Item env:CLAUDE_SWITCHER_ROOT -ErrorAction SilentlyContinue
        }
        $line = (Get-Content -Raw $script:probe).Trim()
        $line | Should -Match 'args=--resume'
        $line | Should -Match ([regex]::Escape("env=$(Join-Path $script:root 'work')"))
    }

    It 'accepts the --profile=<name> form through the shim' {
        $env:CLAUDE_SWITCHER_ROOT = $script:root
        Push-Location $script:cwd
        try {
            & pwsh -NoProfile -File $script:shim --profile=work
        } finally {
            Pop-Location
            Remove-Item env:CLAUDE_SWITCHER_ROOT -ErrorAction SilentlyContinue
        }
        $line = (Get-Content -Raw $script:probe).Trim()
        $line | Should -Match ([regex]::Escape("env=$(Join-Path $script:root 'work')"))
    }
}
