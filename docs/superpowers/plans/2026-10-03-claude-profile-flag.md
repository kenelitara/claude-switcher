# `claude --profile` Override Flag Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `claude --profile <name>` so a single `claude` invocation can select an account, ignoring `claude-account.json` and any preset `CLAUDE_CONFIG_DIR`.

**Architecture:** A new pure argv-parsing module (`lib/Args.psm1`) extracts the flag; `Resolve-ProfileForCwd` gains an `-ExplicitProfile` parameter that becomes the highest-precedence resolution source; the shim (`bin/Invoke-ClaudeShim.ps1`) wires the two together and forwards the flag-stripped argv to the real binary. Reserved sentinel names `personal`/`none` force the personal account.

**Tech Stack:** Windows 11, PowerShell 7+, Pester 5.

**Spec:** `docs/superpowers/specs/2026-10-03-claude-profile-flag-design.md`

**Note on naming:** the spec wrote the parser parameter as `-Args`; this plan uses `-Arguments` because `$Args` is a PowerShell automatic variable. The returned object property is still `.Args`, per the spec.

**Test commands assume Pester 5 is installed.** If `Invoke-Pester` is missing: `Install-Module Pester -Scope CurrentUser -Force`.

---

### Task 1: `lib/Args.psm1` — `Split-ProfileFlag`

**Files:**
- Create: `lib/Args.psm1`
- Test: `tests/Args.Tests.ps1`

- [ ] **Step 1: Write the failing tests**

Create `tests/Args.Tests.ps1`:

```powershell
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path tests/Args.Tests.ps1 -Output Detailed"`
Expected: FAIL — `Split-ProfileFlag` is not recognized (module `Args.psm1` does not exist yet).

- [ ] **Step 3: Write the implementation**

Create `lib/Args.psm1`:

```powershell
function Split-ProfileFlag {
    [CmdletBinding()]
    param([string[]]$Arguments)

    $passThrough = [System.Collections.Generic.List[string]]::new()
    $profile     = $null
    $seenProfile = $false

    if ($Arguments) {
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path tests/Args.Tests.ps1 -Output Detailed"`
Expected: PASS — 8 passed.

- [ ] **Step 5: Commit**

```bash
git add lib/Args.psm1 tests/Args.Tests.ps1
git commit -m "feat(args): Split-ProfileFlag parses --profile from argv"
```

---

### Task 2: `Resolve-ProfileForCwd -ExplicitProfile`

**Files:**
- Modify: `lib/Resolve.psm1`
- Test: `tests/Resolve.Tests.ps1` (append a new `Describe` block)

- [ ] **Step 1: Write the failing tests**

Append this `Describe` block to the end of `tests/Resolve.Tests.ps1`:

```powershell
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
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path tests/Resolve.Tests.ps1 -Output Detailed"`
Expected: FAIL — new `Describe` fails because `-ExplicitProfile` is not a parameter (unknown parameter errors).

- [ ] **Step 3: Add the parameter and the highest-precedence branch**

In `lib/Resolve.psm1`, change the parameter block of `Resolve-ProfileForCwd` to add `-ExplicitProfile`:

```powershell
function Resolve-ProfileForCwd {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Cwd,
        [Parameter(Mandatory)][string]$ProfilesRoot,
        [string]$PresetConfigDir,
        [string]$ExplicitProfile
    )
```

Then insert this block immediately after the closing `)` of the parameter block (i.e. before the existing `if (-not [string]::IsNullOrWhiteSpace($PresetConfigDir))` check):

```powershell
    if (-not [string]::IsNullOrWhiteSpace($ExplicitProfile)) {
        $name = $ExplicitProfile.Trim()
        if ($name -in @('personal', 'none')) {
            return [pscustomobject]@{
                Source     = 'explicit-personal'
                ProfileDir = $null
                Reason     = "personal (~\.claude) — forced by --profile $name"
            }
        }
        if (-not (Test-ProfileExists -ProfilesRoot $ProfilesRoot -Name $name)) {
            throw "claude-switcher: account '$name' is not configured. Run: claude-switch add $name"
        }
        return [pscustomobject]@{
            Source     = 'explicit'
            ProfileDir = Get-ProfileDir -ProfilesRoot $ProfilesRoot -Name $name
            Reason     = "$name — from --profile"
        }
    }
```

Leave the rest of the function (env-bypass, project, default, personal branches) unchanged. `Export-ModuleMember` is unchanged.

- [ ] **Step 4: Run tests to verify they pass**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path tests/Resolve.Tests.ps1 -Output Detailed"`
Expected: PASS — all pre-existing cases plus the 6 new ones.

- [ ] **Step 5: Commit**

```bash
git add lib/Resolve.psm1 tests/Resolve.Tests.ps1
git commit -m "feat(resolve): explicit --profile overrides every resolution source"
```

---

### Task 3: Wire the flag into the shim

**Files:**
- Modify: `bin/Invoke-ClaudeShim.ps1`
- Test: `tests/Integration.Tests.ps1` (append `It` blocks into the existing `Describe`)

- [ ] **Step 1: Write the failing tests**

Insert these `It` blocks inside the existing `Describe 'Invoke-ClaudeShim'` block in `tests/Integration.Tests.ps1` — immediately before the closing `}` of that `Describe` (after the last existing `It 'bypasses routing when CLAUDE_CONFIG_DIR is preset'` block). They reuse the existing `BeforeEach` fixtures (`$script:root` with a `work` dir, `$script:cwd`, the fake `claude.cmd` probe, and `$script:shim`):

```powershell
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
        Push-Location $script:cwd
        try {
            & pwsh -NoProfile -File $script:shim --profile personal
        } finally {
            Pop-Location
            Remove-Item env:CLAUDE_SWITCHER_ROOT -ErrorAction SilentlyContinue
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
            $out | Should -Match 'requires a profile name'
        } finally {
            Pop-Location
            Remove-Item env:CLAUDE_SWITCHER_ROOT -ErrorAction SilentlyContinue
        }
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path tests/Integration.Tests.ps1 -Output Detailed"`
Expected: FAIL — the shim does not yet parse `--profile`, so `--profile work --resume` forwards `--profile` verbatim (the `Should -Not -Match 'profile'` assertion fails), `--profile personal` still routes to `work` via the project file, and `--profile ghost` / bare `--profile` do not produce the expected stderr.

- [ ] **Step 3: Update the shim**

Replace the body of `bin/Invoke-ClaudeShim.ps1` (from the `Import-Module` lines down) with the following. The `param` block, `$ErrorActionPreference`, and `$root` resolution at the top are unchanged; only add the `Args.psm1` import, the parse step, the `-ExplicitProfile` argument, the `switch` over `$decision.Source`, and the stripped-argv forward:

```powershell
$libRoot = Resolve-Path (Join-Path $PSScriptRoot '..\lib')
Import-Module (Join-Path $libRoot 'Schema.psm1')
Import-Module (Join-Path $libRoot 'Profiles.psm1')
Import-Module (Join-Path $libRoot 'Resolve.psm1')
Import-Module (Join-Path $libRoot 'Args.psm1')

$split = Split-ProfileFlag -Arguments $ClaudeArgs
if ($split.Error) {
    [Console]::Error.WriteLine($split.Error)
    exit 1
}

try {
    $decision = Resolve-ProfileForCwd `
        -Cwd (Get-Location).Path `
        -ProfilesRoot $root `
        -PresetConfigDir $env:CLAUDE_CONFIG_DIR `
        -ExplicitProfile $split.Profile
} catch {
    Write-Error $_.Exception.Message
    exit 1
}

switch ($decision.Source) {
    'env-bypass' {
        [Console]::Error.WriteLine("claude-switcher: $($decision.Reason), bypassing")
    }
    'explicit-personal' {
        Remove-Item env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue
    }
    'explicit' {
        $env:CLAUDE_CONFIG_DIR = $decision.ProfileDir
    }
    default {
        if ($decision.ProfileDir) { $env:CLAUDE_CONFIG_DIR = $decision.ProfileDir }
    }
}

$real = Get-RealClaudeBinary
& $real @($split.Args)
exit $LASTEXITCODE
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path tests/Integration.Tests.ps1 -Output Detailed"`
Expected: PASS — the 4 pre-existing cases plus the 5 new ones.

- [ ] **Step 5: Run the whole suite**

Run: `pwsh -NoProfile -Command ". ./PesterConfig.ps1; Invoke-Pester -Configuration \$PesterPreference"`
Expected: PASS — all test files green, exit 0.

- [ ] **Step 6: Commit**

```bash
git add bin/Invoke-ClaudeShim.ps1 tests/Integration.Tests.ps1
git commit -m "feat(shim): consume --profile, force personal, strip flag before forwarding"
```

---

### Task 4: Document the flag

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add a usage section**

In `README.md`, insert this section immediately after the "Use it in a project" section (after the line "Outside any folder with `claude-account.json`, `claude` uses your personal account exactly like before.") and before "## Subcommands":

```markdown
## Override the account for one invocation

```powershell
claude --profile work       # use the "work" account, ignoring claude-account.json
claude --profile personal   # force your personal account (~\.claude)
claude --profile none       # same as personal
```

`--profile` wins over everything else — the project file, the configured default, and even
a preset `CLAUDE_CONFIG_DIR`. The flag is consumed by the shim and never reaches the real
`claude` CLI. Because `personal` and `none` are reserved names, a profile literally named
`personal` or `none` can't be selected this way.
```

- [ ] **Step 2: Verify the rendered section**

Run: `pwsh -NoProfile -Command "Get-Content -Raw README.md | Select-String -Pattern '--profile work' -Quiet"`
Expected: `True`.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: document claude --profile override"
```

---

## Self-Review

**Spec coverage:**
- Invocation form `claude --profile <name>` → Tasks 1, 3.
- No short alias → satisfied by omission (no `-p` handling anywhere).
- Sentinel `personal`/`none` forces personal → Task 2 (resolution) + Task 3 (clears env var).
- `--profile` beats preset `CLAUDE_CONFIG_DIR` → Task 2 (branch order) + Task 3 step 1 test.
- `--profile <name>` and `--profile=<name>` forms; missing value error; duplicate error; `--` terminator → Task 1.
- Stripped argv forwarded to real binary → Task 3 (`& $real @($split.Args)`).
- Unknown profile message → Task 2 (throws existing message) + Task 3 test.
- README note on reserved names → Task 4.
- `claude-switch` CLI untouched → no task modifies `bin/claude-switch.ps1` (correct per spec).

**Placeholder scan:** no TBD/TODO; every code step contains complete code.

**Type consistency:** `Split-ProfileFlag` returns `.Args`/`.Profile`/`.Error` in Task 1 and is consumed identically in Task 3. `Resolve-ProfileForCwd` returns `Source` values `explicit` / `explicit-personal` in Task 2 and the shim `switch` in Task 3 matches those exact strings. Parameter names (`-ExplicitProfile`, `-Arguments`) are consistent across tasks.
