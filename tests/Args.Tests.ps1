BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\lib\Args.psm1') -Force
}

Describe 'Split-ProfileFlag' {
    It 'passes args through unchanged when no flag is present' {
        $r = Split-ProfileFlag -Arguments @('hello','world')
        $r.Profile | Should -BeNullOrEmpty
        $r.Error   | Should -BeNullOrEmpty
        $r.Args    | Should -Be @('hello','world')
    }

    It 'extracts "--profile work" and removes both tokens' {
        $r = Split-ProfileFlag -Arguments @('--profile','work','--resume')
        $r.Profile | Should -Be 'work'
        $r.Error   | Should -BeNullOrEmpty
        $r.Args    | Should -Be @('--resume')
    }

    It 'extracts the "--profile=work" form' {
        $r = Split-ProfileFlag -Arguments @('--profile=work','--resume')
        $r.Profile | Should -Be 'work'
        $r.Args    | Should -Be @('--resume')
    }

    It 'errors when --profile has no value' {
        $r = Split-ProfileFlag -Arguments @('--resume','--profile')
        $r.Error   | Should -Match 'requires a profile name'
        $r.Args    | Should -BeNullOrEmpty
        $r.Profile | Should -BeNullOrEmpty
    }

    It 'errors on "--profile=" with an empty value' {
        $r = Split-ProfileFlag -Arguments @('--profile=')
        $r.Error | Should -Match 'requires a profile name'
    }

    It 'errors when --profile is given more than once' {
        $r = Split-ProfileFlag -Arguments @('--profile','work','--profile','client')
        $r.Error | Should -Match 'more than once'
    }

    It 'does not parse --profile after a bare -- terminator' {
        $r = Split-ProfileFlag -Arguments @('--','--profile','work')
        $r.Profile | Should -BeNullOrEmpty
        $r.Error   | Should -BeNullOrEmpty
        $r.Args    | Should -Be @('--','--profile','work')
    }

    It 'preserves surrounding args and order' {
        $r = Split-ProfileFlag -Arguments @('--resume','--profile','work','prompt text')
        $r.Args    | Should -Be @('--resume','prompt text')
        $r.Profile | Should -Be 'work'
    }
}
