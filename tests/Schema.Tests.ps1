BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\lib\Schema.psm1') -Force
    $script:tmp = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid())
    New-Item -ItemType Directory -Path $script:tmp | Out-Null
}

AfterAll {
    if (Test-Path $script:tmp) { Remove-Item -Recurse -Force $script:tmp }
}

Describe 'Read-AccountConfig' {
    It 'returns the account name for a valid file' {
        $f = Join-Path $script:tmp 'ok.json'
        Set-Content -LiteralPath $f -Encoding utf8NoBOM -Value '{ "account": "work" }'
        (Read-AccountConfig -Path $f).account | Should -Be 'work'
    }

    It 'tolerates a UTF-8 BOM' {
        $f = Join-Path $script:tmp 'bom.json'
        $bytes = [byte[]](0xEF,0xBB,0xBF) + [System.Text.Encoding]::UTF8.GetBytes('{"account":"x"}')
        [System.IO.File]::WriteAllBytes($f, $bytes)
        (Read-AccountConfig -Path $f).account | Should -Be 'x'
    }

    It 'ignores extra unknown fields' {
        $f = Join-Path $script:tmp 'extra.json'
        Set-Content -LiteralPath $f -Encoding utf8NoBOM -Value '{ "account": "y", "future": 42 }'
        (Read-AccountConfig -Path $f).account | Should -Be 'y'
    }

    It 'throws on malformed JSON' {
        $f = Join-Path $script:tmp 'bad.json'
        Set-Content -LiteralPath $f -Encoding utf8NoBOM -Value '{ not json'
        { Read-AccountConfig -Path $f } | Should -Throw '*not valid JSON*'
    }

    It 'throws on missing account field' {
        $f = Join-Path $script:tmp 'missing.json'
        Set-Content -LiteralPath $f -Encoding utf8NoBOM -Value '{}'
        { Read-AccountConfig -Path $f } | Should -Throw '*non-empty "account" field*'
    }

    It 'throws on empty account field' {
        $f = Join-Path $script:tmp 'empty.json'
        Set-Content -LiteralPath $f -Encoding utf8NoBOM -Value '{ "account": "" }'
        { Read-AccountConfig -Path $f } | Should -Throw '*non-empty "account" field*'
    }

    It 'throws on non-string account field' {
        $f = Join-Path $script:tmp 'wrongtype.json'
        Set-Content -LiteralPath $f -Encoding utf8NoBOM -Value '{ "account": 5 }'
        { Read-AccountConfig -Path $f } | Should -Throw '*non-empty "account" field*'
    }

    It 'throws on missing file' {
        { Read-AccountConfig -Path (Join-Path $script:tmp 'does-not-exist.json') } |
            Should -Throw '*does-not-exist.json*'
    }
}

Describe 'SwitcherConfig round-trip' {
    BeforeEach {
        $script:cfg = Join-Path $script:tmp ([guid]::NewGuid().ToString() + '.json')
    }

    It 'returns a default-null object when file is missing' {
        $r = Read-SwitcherConfig -Path $script:cfg
        $r.default | Should -BeNullOrEmpty
    }

    It 'round-trips a default name' {
        Write-SwitcherConfig -Path $script:cfg -Default 'work'
        (Read-SwitcherConfig -Path $script:cfg).default | Should -Be 'work'
    }

    It 'round-trips a null default' {
        Write-SwitcherConfig -Path $script:cfg -Default $null
        (Read-SwitcherConfig -Path $script:cfg).default | Should -BeNullOrEmpty
    }

    It 'writes UTF-8 without BOM' {
        Write-SwitcherConfig -Path $script:cfg -Default 'x'
        $bytes = [System.IO.File]::ReadAllBytes($script:cfg)
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeFalse
    }
}
