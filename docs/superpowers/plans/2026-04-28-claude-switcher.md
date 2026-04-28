# claude-switcher Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Per-folder Claude Code account switching on Windows. A `claude-account.json` at a project root selects which credentials are used; folders without it use the personal account at `~\.claude`.

**Architecture:** Three PowerShell components — a shim that resolves which profile to use based on `./claude-account.json`, a management CLI (`claude-switch`) for adding/listing/removing profiles, and an installer that wires both into the user's `$PROFILE` as functions. Account isolation is achieved by setting `CLAUDE_CONFIG_DIR` per child-process invocation; no symlinks, no credential copying.

**Tech Stack:** PowerShell 7+, Pester 5.x for tests. No other runtime dependencies. Project root: `D:\Workspace Elitara\claude-switcher`.

---

## File Structure

```
claude-switcher/
├── bin/
│   ├── Invoke-ClaudeShim.ps1       # routing: reads CWD config, sets env, runs real claude
│   ├── claude-switch.ps1           # management CLI entry point with subcommand dispatch
│   └── profile-snippet.ps1         # dot-sourced from $PROFILE; defines claude + claude-switch fns
├── lib/
│   ├── Schema.psm1                 # Read-AccountConfig, Read/Write-SwitcherConfig
│   ├── Profiles.psm1               # Get-Profiles, Get-/Set-DefaultProfile, Get-RealClaudeBinary
│   └── Resolve.psm1                # Resolve-ProfileForCwd — the routing core
├── tests/
│   ├── Schema.Tests.ps1
│   ├── Profiles.Tests.ps1
│   ├── Resolve.Tests.ps1
│   ├── CLI.Tests.ps1
│   └── Integration.Tests.ps1       # uses fake claude.cmd
├── install.ps1
├── uninstall.ps1
├── README.md
└── .gitignore
```

**Boundaries:**
- `Schema.psm1` — pure JSON I/O. Knows nothing about routing or profiles.
- `Profiles.psm1` — directory enumeration and global registry state. Depends on `Schema.psm1`.
- `Resolve.psm1` — pure function: `(cwd, env, profilesRoot, switcherConfig) → (profileDir, reason) | error`. Depends on both.
- `bin/*.ps1` — thin shells. Parse args, call lib functions, format output. Minimal logic.

---

## Task 1: Project scaffold

**Files:**
- Create: `D:\Workspace Elitara\claude-switcher\.gitignore`
- Create: `D:\Workspace Elitara\claude-switcher\PesterConfig.ps1`
- Create empty placeholders: `bin\`, `lib\`, `tests\` directories

- [ ] **Step 1: Initialize git repo if not present**

```powershell
cd 'D:\Workspace Elitara\claude-switcher'
if (-not (Test-Path .git)) { git init }
```

Expected: either "Reinitialized existing Git repository" or a fresh init. The `docs/` tree already exists from brainstorming.

- [ ] **Step 2: Create directory skeleton**

```powershell
New-Item -ItemType Directory -Force -Path bin, lib, tests | Out-Null
```

- [ ] **Step 3: Write `.gitignore`**

```
# Pester output
testResults.xml

# PowerShell module cache
*.psd1.bak

# IDE
.vscode/
.idea/

# OS
Thumbs.db
.DS_Store
```

- [ ] **Step 4: Verify Pester 5 is installed**

```powershell
$p = Get-Module -ListAvailable Pester | Where-Object { $_.Version.Major -ge 5 } | Select-Object -First 1
if (-not $p) { Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -Force -SkipPublisherCheck }
$p.Version
```

Expected: a 5.x version printed.

- [ ] **Step 5: Write `PesterConfig.ps1` (used by every test file run later)**

```powershell
$PesterPreference = [PesterConfiguration]::Default
$PesterPreference.Run.Path = 'tests'
$PesterPreference.Output.Verbosity = 'Detailed'
$PesterPreference.Run.Exit = $true
```

- [ ] **Step 6: Commit**

```powershell
git add .gitignore PesterConfig.ps1 bin lib tests docs/superpowers/specs docs/superpowers/plans
git commit -m "chore: scaffold claude-switcher project layout"
```

---

## Task 2: `Schema.psm1` — `Read-AccountConfig`

Pure parser for `./claude-account.json`. Returns the validated object or throws a descriptive error.

**Files:**
- Create: `lib\Schema.psm1`
- Create: `tests\Schema.Tests.ps1`

- [ ] **Step 1: Write the failing tests**

`tests\Schema.Tests.ps1`:

```powershell
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
}
```

- [ ] **Step 2: Run tests, verify they fail**

```powershell
Invoke-Pester tests\Schema.Tests.ps1
```

Expected: all six tests fail with "Read-AccountConfig is not recognized" or similar.

- [ ] **Step 3: Implement `Read-AccountConfig`**

`lib\Schema.psm1`:

```powershell
function Read-AccountConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding utf8
    try {
        $obj = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "claude-switcher: $Path is not valid JSON: $($_.Exception.Message)"
    }

    if (-not $obj.PSObject.Properties.Match('account').Count -or
        $obj.account -isnot [string] -or
        [string]::IsNullOrWhiteSpace($obj.account)) {
        throw "claude-switcher: $Path must contain a non-empty `"account`" field"
    }

    return [pscustomobject]@{ account = $obj.account }
}

Export-ModuleMember -Function Read-AccountConfig
```

- [ ] **Step 4: Run tests, verify they pass**

```powershell
Invoke-Pester tests\Schema.Tests.ps1
```

Expected: 6/6 pass.

- [ ] **Step 5: Commit**

```powershell
git add lib\Schema.psm1 tests\Schema.Tests.ps1
git commit -m "feat(schema): Read-AccountConfig with validation"
```

---

## Task 3: `Schema.psm1` — `Read-SwitcherConfig` and `Write-SwitcherConfig`

The global registry file at `~\.claude-accounts\.switcher.json` carries `{ "default": "<name>" | null }`.

**Files:**
- Modify: `lib\Schema.psm1` (append two functions)
- Modify: `tests\Schema.Tests.ps1` (append a Describe block)

- [ ] **Step 1: Append failing tests to `tests\Schema.Tests.ps1`**

Add at the bottom of the file:

```powershell
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
```

- [ ] **Step 2: Run tests, verify the four new ones fail**

```powershell
Invoke-Pester tests\Schema.Tests.ps1
```

Expected: 6 pass, 4 fail with "Read-SwitcherConfig is not recognized".

- [ ] **Step 3: Implement the two functions**

Append to `lib\Schema.psm1` (and update the `Export-ModuleMember` line):

```powershell
function Read-SwitcherConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ default = $null }
    }

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding utf8
    try {
        $obj = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "claude-switcher: $Path is not valid JSON: $($_.Exception.Message)"
    }

    $val = $null
    if ($obj.PSObject.Properties.Match('default').Count -and $obj.default -is [string] -and -not [string]::IsNullOrWhiteSpace($obj.default)) {
        $val = $obj.default
    }
    return [pscustomobject]@{ default = $val }
}

function Write-SwitcherConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [AllowNull()][string]$Default
    )

    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }

    $obj = [pscustomobject]@{ default = $Default }
    $json = $obj | ConvertTo-Json -Depth 4
    Set-Content -LiteralPath $Path -Value $json -Encoding utf8NoBOM
}
```

Update the export line at the bottom:

```powershell
Export-ModuleMember -Function Read-AccountConfig, Read-SwitcherConfig, Write-SwitcherConfig
```

- [ ] **Step 4: Run tests, verify all pass**

```powershell
Invoke-Pester tests\Schema.Tests.ps1
```

Expected: 10/10 pass.

- [ ] **Step 5: Commit**

```powershell
git add lib\Schema.psm1 tests\Schema.Tests.ps1
git commit -m "feat(schema): Read/Write-SwitcherConfig round-trip"
```

---

## Task 4: `Profiles.psm1` — directory enumeration and path helpers

Knows the on-disk layout. Pure functions over a `$ProfilesRoot` parameter so tests can use a temp dir.

**Files:**
- Create: `lib\Profiles.psm1`
- Create: `tests\Profiles.Tests.ps1`

- [ ] **Step 1: Write failing tests**

`tests\Profiles.Tests.ps1`:

```powershell
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
```

- [ ] **Step 2: Run, verify failures**

```powershell
Invoke-Pester tests\Profiles.Tests.ps1
```

Expected: 5 fail with "Get-Profiles is not recognized".

- [ ] **Step 3: Implement**

`lib\Profiles.psm1`:

```powershell
function Get-Profiles {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProfilesRoot)

    if (-not (Test-Path -LiteralPath $ProfilesRoot)) {
        New-Item -ItemType Directory -Force -Path $ProfilesRoot | Out-Null
        return @()
    }

    Get-ChildItem -LiteralPath $ProfilesRoot -Directory -Force |
        Where-Object { -not $_.Name.StartsWith('.') } |
        Sort-Object Name |
        ForEach-Object { $_.Name }
}

function Get-ProfileDir {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProfilesRoot,
        [Parameter(Mandatory)][string]$Name
    )
    Join-Path $ProfilesRoot $Name
}

function Test-ProfileExists {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProfilesRoot,
        [Parameter(Mandatory)][string]$Name
    )
    Test-Path -LiteralPath (Get-ProfileDir -ProfilesRoot $ProfilesRoot -Name $Name) -PathType Container
}

Export-ModuleMember -Function Get-Profiles, Get-ProfileDir, Test-ProfileExists
```

- [ ] **Step 4: Verify pass**

```powershell
Invoke-Pester tests\Profiles.Tests.ps1
```

Expected: 5/5 pass.

- [ ] **Step 5: Commit**

```powershell
git add lib\Profiles.psm1 tests\Profiles.Tests.ps1
git commit -m "feat(profiles): enumerate and resolve profile dirs"
```

---

## Task 5: `Profiles.psm1` — default get/set + real-binary discovery

Three more functions: `Get-DefaultProfile`, `Set-DefaultProfile`, `Get-RealClaudeBinary`.

**Files:**
- Modify: `lib\Profiles.psm1` (append three functions, update Export)
- Modify: `tests\Profiles.Tests.ps1` (append two Describe blocks)

- [ ] **Step 1: Append failing tests**

Append to `tests\Profiles.Tests.ps1`:

```powershell
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
        Mock -ModuleName Profiles Get-Command {
            [pscustomobject]@{ Source = 'C:\fake\claude.cmd'; CommandType = 'Application' }
        } -ParameterFilter { $Name -eq 'claude' }
        Get-RealClaudeBinary | Should -Be 'C:\fake\claude.cmd'
    }

    It 'throws a descriptive error when no claude is on PATH' {
        Mock -ModuleName Profiles Get-Command { $null } -ParameterFilter { $Name -eq 'claude' }
        { Get-RealClaudeBinary } | Should -Throw "*real 'claude' executable not found on PATH*"
    }
}
```

- [ ] **Step 2: Run, verify failures**

```powershell
Invoke-Pester tests\Profiles.Tests.ps1
```

Expected: prior 5 still pass, 6 new fail with "is not recognized".

- [ ] **Step 3: Implement**

Append to `lib\Profiles.psm1` (and update the Export line):

```powershell
function Get-DefaultProfile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProfilesRoot)

    Import-Module (Join-Path $PSScriptRoot 'Schema.psm1') -Force
    $cfg = Read-SwitcherConfig -Path (Join-Path $ProfilesRoot '.switcher.json')
    return $cfg.default
}

function Set-DefaultProfile {
    [CmdletBinding(DefaultParameterSetName='Set')]
    param(
        [Parameter(Mandatory)][string]$ProfilesRoot,
        [Parameter(Mandatory, ParameterSetName='Set')][string]$Name,
        [Parameter(Mandatory, ParameterSetName='Reset')][switch]$Reset
    )

    Import-Module (Join-Path $PSScriptRoot 'Schema.psm1') -Force
    $path = Join-Path $ProfilesRoot '.switcher.json'

    if ($Reset) {
        Write-SwitcherConfig -Path $path -Default $null
        return
    }

    if (-not (Test-ProfileExists -ProfilesRoot $ProfilesRoot -Name $Name)) {
        throw "claude-switcher: account '$Name' is not configured. Run: claude-switch add $Name"
    }
    Write-SwitcherConfig -Path $path -Default $Name
}

function Get-RealClaudeBinary {
    [CmdletBinding()] param()
    $cmd = Get-Command claude -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $cmd) {
        throw "claude-switcher: real 'claude' executable not found on PATH"
    }
    return $cmd.Source
}

Export-ModuleMember -Function Get-Profiles, Get-ProfileDir, Test-ProfileExists, Get-DefaultProfile, Set-DefaultProfile, Get-RealClaudeBinary
```

- [ ] **Step 4: Verify pass**

```powershell
Invoke-Pester tests\Profiles.Tests.ps1
```

Expected: 11/11 pass. (If the `Get-RealClaudeBinary` mock tests have trouble locating `Get-Command` for mocking, the workaround is to wrap `Get-Command` in a local helper function and mock that — adjust Profiles.psm1 accordingly: define `function script:Find-Application { Get-Command @args }`, call that from `Get-RealClaudeBinary`, and mock `Find-Application` in tests.)

- [ ] **Step 5: Commit**

```powershell
git add lib\Profiles.psm1 tests\Profiles.Tests.ps1
git commit -m "feat(profiles): default get/set + real-binary discovery"
```

---

## Task 6: `Resolve.psm1` — `Resolve-ProfileForCwd` (the routing core)

The single function the shim calls. Pure: takes the world as parameters, returns a decision.

Returns a `[pscustomobject]@{ ProfileDir = <path|null>; Reason = <string>; Source = 'project'|'default'|'personal'|'env-bypass' }`. `ProfileDir` of `$null` means "leave `CLAUDE_CONFIG_DIR` unset, let claude use ~\.claude". The shim knows what to do with each `Source`.

**Files:**
- Create: `lib\Resolve.psm1`
- Create: `tests\Resolve.Tests.ps1`

- [ ] **Step 1: Write failing tests (table-driven)**

`tests\Resolve.Tests.ps1`:

```powershell
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
```

- [ ] **Step 2: Run, verify all fail**

```powershell
Invoke-Pester tests\Resolve.Tests.ps1
```

Expected: 7 fail with "Resolve-ProfileForCwd is not recognized".

- [ ] **Step 3: Implement**

`lib\Resolve.psm1`:

```powershell
function Resolve-ProfileForCwd {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Cwd,
        [Parameter(Mandatory)][string]$ProfilesRoot,
        [string]$PresetConfigDir
    )

    Import-Module (Join-Path $PSScriptRoot 'Schema.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'Profiles.psm1') -Force

    if (-not [string]::IsNullOrWhiteSpace($PresetConfigDir)) {
        return [pscustomobject]@{
            Source = 'env-bypass'
            ProfileDir = $null
            Reason = "CLAUDE_CONFIG_DIR already set to $PresetConfigDir"
        }
    }

    $projectFile = Join-Path $Cwd 'claude-account.json'
    if (Test-Path -LiteralPath $projectFile) {
        $cfg = Read-AccountConfig -Path $projectFile
        if (-not (Test-ProfileExists -ProfilesRoot $ProfilesRoot -Name $cfg.account)) {
            throw "claude-switcher: account '$($cfg.account)' is not configured. Run: claude-switch add $($cfg.account)"
        }
        return [pscustomobject]@{
            Source = 'project'
            ProfileDir = Get-ProfileDir -ProfilesRoot $ProfilesRoot -Name $cfg.account
            Reason = "$($cfg.account) — from .\claude-account.json"
        }
    }

    $default = Get-DefaultProfile -ProfilesRoot $ProfilesRoot
    if ($default -and (Test-ProfileExists -ProfilesRoot $ProfilesRoot -Name $default)) {
        return [pscustomobject]@{
            Source = 'default'
            ProfileDir = Get-ProfileDir -ProfilesRoot $ProfilesRoot -Name $default
            Reason = "$default — configured default override"
        }
    }

    return [pscustomobject]@{
        Source = 'personal'
        ProfileDir = $null
        Reason = 'personal (~\.claude) — no claude-account.json'
    }
}

Export-ModuleMember -Function Resolve-ProfileForCwd
```

- [ ] **Step 4: Verify pass**

```powershell
Invoke-Pester tests\Resolve.Tests.ps1
```

Expected: 7/7 pass.

- [ ] **Step 5: Commit**

```powershell
git add lib\Resolve.psm1 tests\Resolve.Tests.ps1
git commit -m "feat(resolve): table-driven routing for cwd → profile decision"
```

---

## Task 7: `bin\claude-switch.ps1` — argument parsing & subcommand dispatch (read-only commands)

This task implements the CLI entry point and the read-only subcommands: `current`, `list`, `where`, `help`. Mutating subcommands come in Task 8 and 9.

**Files:**
- Create: `bin\claude-switch.ps1`
- Create: `tests\CLI.Tests.ps1`

- [ ] **Step 1: Write failing tests for read-only subcommands**

`tests\CLI.Tests.ps1`:

```powershell
BeforeAll {
    $script:cli = (Resolve-Path (Join-Path $PSScriptRoot '..\bin\claude-switch.ps1')).Path
    function Invoke-Cli {
        param([string]$Root, [string[]]$Args, [string]$Cwd = (Get-Location).Path)
        $env:CLAUDE_SWITCHER_ROOT = $Root
        $out = & pwsh -NoProfile -File $script:cli @Args 2>&1 | Out-String
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
```

- [ ] **Step 2: Run, verify fail**

```powershell
Invoke-Pester tests\CLI.Tests.ps1
```

Expected: all fail because `claude-switch.ps1` does not exist yet.

- [ ] **Step 3: Implement the script with read-only commands**

`bin\claude-switch.ps1`:

```powershell
#!/usr/bin/env pwsh
[CmdletBinding()]
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)

$ErrorActionPreference = 'Stop'

$root = $env:CLAUDE_SWITCHER_ROOT
if ([string]::IsNullOrWhiteSpace($root)) {
    $root = Join-Path $env:USERPROFILE '.claude-accounts'
}
if (-not (Test-Path -LiteralPath $root)) {
    New-Item -ItemType Directory -Force -Path $root | Out-Null
}

$libRoot = Resolve-Path (Join-Path $PSScriptRoot '..\lib')
Import-Module (Join-Path $libRoot 'Schema.psm1')   -Force
Import-Module (Join-Path $libRoot 'Profiles.psm1') -Force
Import-Module (Join-Path $libRoot 'Resolve.psm1')  -Force

function Show-Usage {
@'
Usage: claude-switch <command> [args]

Commands:
  add <name>         Create a profile and launch claude so you can /login.
  list               List all profiles, marking personal (fallback) and current.
  remove <name>      Delete a profile directory (asks for confirmation).
  current            Print which profile resolves in the current directory.
  default <name>     Override the fallback (instead of personal).
  default --reset    Restore personal as the fallback.
  where <name>       Print the absolute path of a profile dir.
  init [name]        Write a claude-account.json into the current directory.
  help               Show this message.
'@
}

if (-not $Args -or $Args.Count -eq 0 -or $Args[0] -in @('help','-h','--help')) {
    Show-Usage
    exit 0
}

$cmd  = $Args[0]
$rest = if ($Args.Count -gt 1) { $Args[1..($Args.Count - 1)] } else { @() }

switch ($cmd) {
    'list' {
        $profiles = Get-Profiles -ProfilesRoot $root
        $default  = Get-DefaultProfile -ProfilesRoot $root
        $resolved = Resolve-ProfileForCwd -Cwd (Get-Location).Path -ProfilesRoot $root -PresetConfigDir $env:CLAUDE_CONFIG_DIR

        $personalMarker = ''
        if ($resolved.Source -eq 'personal') { $personalMarker = ' [current]' }
        Write-Output ("personal (fallback)" + $personalMarker)

        foreach ($p in $profiles) {
            $marks = @()
            if ($p -eq $default) { $marks += 'default' }
            if ($resolved.Source -in @('project','default') -and
                $resolved.ProfileDir -eq (Get-ProfileDir -ProfilesRoot $root -Name $p)) {
                $marks += 'current'
            }
            $tag = if ($marks) { " [" + ($marks -join ', ') + "]" } else { '' }
            Write-Output ("  $p$tag")
        }
        exit 0
    }

    'where' {
        if (-not $rest -or $rest.Count -ne 1) { throw "claude-switcher: 'where' requires a single profile name" }
        $name = $rest[0]
        if (-not (Test-ProfileExists -ProfilesRoot $root -Name $name)) {
            throw "claude-switcher: account '$name' is not configured"
        }
        Write-Output (Get-ProfileDir -ProfilesRoot $root -Name $name)
        exit 0
    }

    'current' {
        $r = Resolve-ProfileForCwd -Cwd (Get-Location).Path -ProfilesRoot $root -PresetConfigDir $env:CLAUDE_CONFIG_DIR
        Write-Output $r.Reason
        exit 0
    }

    default {
        Write-Error "claude-switcher: unknown subcommand '$cmd'. Run 'claude-switch help'."
        exit 2
    }
}
```

- [ ] **Step 4: Verify**

```powershell
Invoke-Pester tests\CLI.Tests.ps1
```

Expected: 5/5 pass.

- [ ] **Step 5: Commit**

```powershell
git add bin\claude-switch.ps1 tests\CLI.Tests.ps1
git commit -m "feat(cli): claude-switch help/list/where/current"
```

---

## Task 8: CLI mutating subcommands — `default`, `init`

**Files:**
- Modify: `bin\claude-switch.ps1` (add two cases to the `switch`)
- Modify: `tests\CLI.Tests.ps1` (append two Describe blocks)

- [ ] **Step 1: Append failing tests**

```powershell
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
        $out | Should -Match 'not configured'
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
        Push-Location $script:cwd
        try {
            Invoke-Cli -Root $script:root -Args @('init','work') | Out-Null
            $f = Join-Path $script:cwd 'claude-account.json'
            (Get-Content -Raw $f | ConvertFrom-Json).account | Should -Be 'work'
        } finally { Pop-Location }
    }

    It 'refuses to overwrite without --force' {
        Push-Location $script:cwd
        try {
            $f = Join-Path $script:cwd 'claude-account.json'
            Set-Content -LiteralPath $f -Encoding utf8NoBOM -Value '{ "account": "old" }'
            $out = Invoke-Cli -Root $script:root -Args @('init','new')
            $out | Should -Match 'already exists'
            (Get-Content -Raw $f | ConvertFrom-Json).account | Should -Be 'old'
        } finally { Pop-Location }
    }
}
```

- [ ] **Step 2: Verify failures**

```powershell
Invoke-Pester tests\CLI.Tests.ps1
```

- [ ] **Step 3: Add the two subcommand cases**

In `bin\claude-switch.ps1`, insert before the `default { ... }` arm:

```powershell
    'default' {
        if (-not $rest) { throw "claude-switcher: 'default' requires <name> or --reset" }
        if ($rest[0] -eq '--reset') {
            Set-DefaultProfile -ProfilesRoot $root -Reset
            Write-Output 'claude-switcher: default reset to personal (~\.claude)'
        } else {
            Set-DefaultProfile -ProfilesRoot $root -Name $rest[0]
            Write-Output "claude-switcher: default set to '$($rest[0])'"
        }
        exit 0
    }

    'init' {
        if (-not $rest) { throw "claude-switcher: 'init' requires <name>" }
        $force = $rest -contains '--force'
        $name  = $rest | Where-Object { $_ -ne '--force' } | Select-Object -First 1
        if (-not $name) { throw "claude-switcher: 'init' requires <name>" }

        $target = Join-Path (Get-Location).Path 'claude-account.json'
        if ((Test-Path -LiteralPath $target) -and -not $force) {
            throw "claude-switcher: $target already exists (use --force to overwrite)"
        }
        $obj  = [pscustomobject]@{ account = $name }
        $json = $obj | ConvertTo-Json -Depth 4
        Set-Content -LiteralPath $target -Value $json -Encoding utf8NoBOM
        Write-Output "claude-switcher: wrote $target"
        exit 0
    }
```

- [ ] **Step 4: Verify**

```powershell
Invoke-Pester tests\CLI.Tests.ps1
```

Expected: all CLI tests pass.

- [ ] **Step 5: Commit**

```powershell
git add bin\claude-switch.ps1 tests\CLI.Tests.ps1
git commit -m "feat(cli): default + init subcommands"
```

---

## Task 9: CLI lifecycle subcommands — `add`, `remove`

`add` creates the profile dir and launches the real claude with `CLAUDE_CONFIG_DIR` pointed at it. `remove` deletes the dir. Both confirm-prompt unless `--force`.

**Files:**
- Modify: `bin\claude-switch.ps1` (add two cases)
- Modify: `tests\CLI.Tests.ps1`

- [ ] **Step 1: Append failing tests**

```powershell
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
        $out | Should -Match 'already exists'
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
        $out | Should -Match 'not configured'
    }

    It 'refuses to remove the configured default without --force' {
        Invoke-Cli -Root $script:root -Args @('default','work') | Out-Null
        # No --force → would prompt; the CLI must early-exit with an error in non-interactive contexts.
        $out = Invoke-Cli -Root $script:root -Args @('remove','work')
        $out | Should -Match 'configured default'
    }
}
```

- [ ] **Step 2: Run, verify failures**

```powershell
Invoke-Pester tests\CLI.Tests.ps1
```

- [ ] **Step 3: Add the cases**

In `bin\claude-switch.ps1`, insert before the `default { ... }` arm:

```powershell
    'add' {
        if (-not $rest) { throw "claude-switcher: 'add' requires <name>" }
        $skipPrompt = $rest -contains '--no-launch-prompt'
        $force      = $rest -contains '--force'
        $name       = $rest | Where-Object { $_ -notlike '--*' } | Select-Object -First 1
        if (-not $name) { throw "claude-switcher: 'add' requires <name>" }

        $dir = Get-ProfileDir -ProfilesRoot $root -Name $name
        if ((Test-Path -LiteralPath $dir) -and -not $force) {
            throw "claude-switcher: profile '$name' already exists at $dir (use --force to reuse)"
        }
        New-Item -ItemType Directory -Force -Path $dir | Out-Null

        if (-not $skipPrompt) {
            Write-Output "claude-switcher: profile '$name' created at $dir."
            Write-Output "Launching 'claude' so you can /login. Press any key to continue, Ctrl+C to skip."
            $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        }

        $real = Get-RealClaudeBinary
        $env:CLAUDE_CONFIG_DIR = $dir
        try {
            & $real
        } finally {
            Remove-Item env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue
        }
        exit 0
    }

    'remove' {
        if (-not $rest) { throw "claude-switcher: 'remove' requires <name>" }
        $force = $rest -contains '--force'
        $name  = $rest | Where-Object { $_ -notlike '--*' } | Select-Object -First 1
        if (-not $name) { throw "claude-switcher: 'remove' requires <name>" }
        if (-not (Test-ProfileExists -ProfilesRoot $root -Name $name)) {
            throw "claude-switcher: account '$name' is not configured"
        }
        $default = Get-DefaultProfile -ProfilesRoot $root
        if ($default -eq $name -and -not $force) {
            throw "claude-switcher: '$name' is the configured default. Run 'claude-switch default --reset' first, or pass --force"
        }
        if (-not $force) {
            Write-Output "claude-switcher: about to delete $(Get-ProfileDir -ProfilesRoot $root -Name $name). Press 'y' to confirm."
            $key = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
            if ($key.Character -ne 'y' -and $key.Character -ne 'Y') {
                Write-Output 'cancelled'
                exit 1
            }
        }
        Remove-Item -Recurse -Force (Get-ProfileDir -ProfilesRoot $root -Name $name)
        if ($default -eq $name) { Set-DefaultProfile -ProfilesRoot $root -Reset }
        Write-Output "claude-switcher: removed '$name'"
        exit 0
    }
```

- [ ] **Step 4: Verify**

```powershell
Invoke-Pester tests\CLI.Tests.ps1
```

Expected: all CLI tests pass.

- [ ] **Step 5: Commit**

```powershell
git add bin\claude-switch.ps1 tests\CLI.Tests.ps1
git commit -m "feat(cli): add + remove lifecycle subcommands"
```

---

## Task 10: `bin\Invoke-ClaudeShim.ps1` — the routing shim

The script the `claude` PowerShell function calls. Resolves the profile, sets `CLAUDE_CONFIG_DIR` for the child, invokes the real `claude.cmd`, propagates the exit code.

**Files:**
- Create: `bin\Invoke-ClaudeShim.ps1`
- Create: `tests\Integration.Tests.ps1`

- [ ] **Step 1: Write the integration test**

`tests\Integration.Tests.ps1`:

```powershell
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
}
```

- [ ] **Step 2: Run, verify failures**

```powershell
Invoke-Pester tests\Integration.Tests.ps1
```

- [ ] **Step 3: Implement the shim**

`bin\Invoke-ClaudeShim.ps1`:

```powershell
#!/usr/bin/env pwsh
[CmdletBinding()]
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$ClaudeArgs)

$ErrorActionPreference = 'Stop'

$root = $env:CLAUDE_SWITCHER_ROOT
if ([string]::IsNullOrWhiteSpace($root)) {
    $root = Join-Path $env:USERPROFILE '.claude-accounts'
}

$libRoot = Resolve-Path (Join-Path $PSScriptRoot '..\lib')
Import-Module (Join-Path $libRoot 'Schema.psm1')   -Force
Import-Module (Join-Path $libRoot 'Profiles.psm1') -Force
Import-Module (Join-Path $libRoot 'Resolve.psm1')  -Force

try {
    $decision = Resolve-ProfileForCwd `
        -Cwd (Get-Location).Path `
        -ProfilesRoot $root `
        -PresetConfigDir $env:CLAUDE_CONFIG_DIR
} catch {
    Write-Error $_.Exception.Message
    exit 1
}

if ($decision.Source -eq 'env-bypass') {
    [Console]::Error.WriteLine("claude-switcher: $($decision.Reason), bypassing")
} elseif ($decision.ProfileDir) {
    $env:CLAUDE_CONFIG_DIR = $decision.ProfileDir
}

$real = Get-RealClaudeBinary
& $real @ClaudeArgs
exit $LASTEXITCODE
```

- [ ] **Step 4: Verify**

```powershell
Invoke-Pester tests\Integration.Tests.ps1
```

Expected: 4/4 pass.

- [ ] **Step 5: Commit**

```powershell
git add bin\Invoke-ClaudeShim.ps1 tests\Integration.Tests.ps1
git commit -m "feat(shim): per-cwd CLAUDE_CONFIG_DIR routing for claude"
```

---

## Task 11: `bin\profile-snippet.ps1` — defines `claude` and `claude-switch` functions

This is the file dot-sourced from the user's `$PROFILE`. It does not run any logic at import; it only defines two functions.

**Files:**
- Create: `bin\profile-snippet.ps1`

- [ ] **Step 1: Write the snippet**

`bin\profile-snippet.ps1`:

```powershell
$script:ClaudeSwitcherRoot = Split-Path -Parent $PSCommandPath

function global:claude {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$ClaudeArgs)
    $shim = Join-Path $script:ClaudeSwitcherRoot 'Invoke-ClaudeShim.ps1'
    & $shim @ClaudeArgs
}

function global:claude-switch {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
    $cli = Join-Path $script:ClaudeSwitcherRoot 'claude-switch.ps1'
    & $cli @Args
}
```

Notes for the engineer:
- `$PSCommandPath` inside a dot-sourced script is the snippet's own path, so `Split-Path -Parent` of it is `bin\`. The two scripts (`Invoke-ClaudeShim.ps1`, `claude-switch.ps1`) live in the same directory.
- `function global:claude` puts the function in the global scope so it shadows the `claude.cmd` Application on the bare word — the goal of the whole exercise.

- [ ] **Step 2: Smoke test manually**

```powershell
. .\bin\profile-snippet.ps1
Get-Command claude -All
```

Expected: at least two entries — `claude` (Function, line 0 in profile-snippet.ps1) at the top, and `claude.cmd` (Application) below it. The function-first ordering is what makes the bare word resolve to the shim.

- [ ] **Step 3: Commit**

```powershell
git add bin\profile-snippet.ps1
git commit -m "feat(profile): claude + claude-switch functions for $PROFILE"
```

---

## Task 12: `install.ps1`

Idempotent installer that appends a marker block to `$PROFILE`.

**Files:**
- Create: `install.ps1`

- [ ] **Step 1: Write the script**

`install.ps1`:

```powershell
#!/usr/bin/env pwsh
[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "claude-switcher requires PowerShell 7 or newer (current: $($PSVersionTable.PSVersion))"
}

$repoRoot = $PSScriptRoot
$snippet  = Join-Path $repoRoot 'bin\profile-snippet.ps1'
if (-not (Test-Path -LiteralPath $snippet)) {
    throw "claude-switcher: $snippet missing — is the repo intact?"
}

$profilePath = $PROFILE.CurrentUserAllHosts
$profileDir  = Split-Path -Parent $profilePath
if (-not (Test-Path -LiteralPath $profileDir)) {
    New-Item -ItemType Directory -Force -Path $profileDir | Out-Null
}
if (-not (Test-Path -LiteralPath $profilePath)) {
    Set-Content -LiteralPath $profilePath -Value '' -Encoding utf8NoBOM
}

$beginMarker = '# >>> claude-switcher >>>'
$endMarker   = '# <<< claude-switcher <<<'
$block = @"
$beginMarker
. '$snippet'
$endMarker
"@

$existing = Get-Content -Raw -LiteralPath $profilePath
$pattern  = "(?ms)$([regex]::Escape($beginMarker)).*?$([regex]::Escape($endMarker))"
if ($existing -match $pattern) {
    $updated = [regex]::Replace($existing, $pattern, $block)
} else {
    $updated = $existing.TrimEnd() + "`r`n`r`n" + $block + "`r`n"
}
Set-Content -LiteralPath $profilePath -Value $updated -Encoding utf8NoBOM

$accountsRoot = Join-Path $env:USERPROFILE '.claude-accounts'
New-Item -ItemType Directory -Force -Path $accountsRoot | Out-Null

Write-Output ''
Write-Output "claude-switcher installed to: $profilePath"
Write-Output 'Next steps:'
Write-Output '  1. Reload your profile in any open terminal:  . $PROFILE'
Write-Output '  2. Add a non-personal account:                claude-switch add work'
Write-Output '  3. Inside a project folder:                   claude-switch init work'
```

- [ ] **Step 2: Smoke test**

Run in a scratch profile (avoid clobbering the real one for now):

```powershell
$origProfile = $PROFILE.CurrentUserAllHosts
$tmpProfile  = Join-Path ([System.IO.Path]::GetTempPath()) "test-profile-$([guid]::NewGuid()).ps1"
$PROFILE = [pscustomobject]@{ CurrentUserAllHosts = $tmpProfile }  # not actually settable; do this in a test instead
```

Just run for real on the user's machine if they're ready, otherwise skip and verify in Task 14 manual smoke checklist.

- [ ] **Step 3: Commit**

```powershell
git add install.ps1
git commit -m "feat(install): idempotent install.ps1 with marker block"
```

---

## Task 13: `uninstall.ps1`

**Files:**
- Create: `uninstall.ps1`

- [ ] **Step 1: Write the script**

`uninstall.ps1`:

```powershell
#!/usr/bin/env pwsh
[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'

$profilePath = $PROFILE.CurrentUserAllHosts
if (-not (Test-Path -LiteralPath $profilePath)) {
    Write-Output "claude-switcher: nothing to do — $profilePath does not exist."
    return
}

$beginMarker = '# >>> claude-switcher >>>'
$endMarker   = '# <<< claude-switcher <<<'
$pattern = "(?ms)\r?\n?$([regex]::Escape($beginMarker)).*?$([regex]::Escape($endMarker))\r?\n?"
$existing = Get-Content -Raw -LiteralPath $profilePath
if ($existing -notmatch $pattern) {
    Write-Output "claude-switcher: marker block not found in $profilePath — nothing to remove."
    return
}
$updated = [regex]::Replace($existing, $pattern, "`r`n")
Set-Content -LiteralPath $profilePath -Value $updated.TrimEnd() -Encoding utf8NoBOM

Write-Output "claude-switcher: removed marker block from $profilePath."
Write-Output "Note: profile directories under $($env:USERPROFILE)\.claude-accounts\ were not deleted."
Write-Output "      To wipe credentials, run:  Remove-Item -Recurse -Force '$env:USERPROFILE\.claude-accounts'"
```

- [ ] **Step 2: Commit**

```powershell
git add uninstall.ps1
git commit -m "feat(install): uninstall.ps1 strips marker block"
```

---

## Task 14: `README.md`

**Files:**
- Create: `README.md`

- [ ] **Step 1: Write README**

`README.md`:

````markdown
# claude-switcher

Per-folder Claude Code account switching for Windows + PowerShell 7.

Drop `claude-account.json` in a project root, run `claude` from anywhere inside that
folder, and the CLI uses the credentials for the named account. Folders without the
file fall back to your personal account at `~\.claude` — the one Claude Code already
manages today, untouched.

## Install

```powershell
.\install.ps1
. $PROFILE   # reload current shell
```

## Add a non-personal account

```powershell
claude-switch add work
# A real `claude` window opens with CLAUDE_CONFIG_DIR pointed at the new profile.
# Run /login (or whatever your installed CLI's login command is) and exit.
```

## Use it in a project

```powershell
cd D:\path\to\some-work-project
claude-switch init work          # writes claude-account.json with { "account": "work" }
claude                            # uses the work account
```

Outside any folder with `claude-account.json`, `claude` uses your personal account
exactly like before.

## Subcommands

| Command | What it does |
| --- | --- |
| `claude-switch add <name>` | Create a profile dir and launch `claude` so you can `/login` into it. |
| `claude-switch list` | List all profiles. Shows personal first, marks default and current. |
| `claude-switch remove <name>` | Delete a profile dir (asks for confirmation). |
| `claude-switch current` | Print which profile resolves in the current directory and why. |
| `claude-switch default <name>` | Override the fallback (instead of personal). |
| `claude-switch default --reset` | Restore personal as the fallback. |
| `claude-switch where <name>` | Print the absolute path of a profile dir. |
| `claude-switch init [name]` | Write `claude-account.json` into the current directory. |

## How it works

The installer adds two PowerShell functions to your `$PROFILE`: `claude` and
`claude-switch`. The `claude` function intercepts the bare word ahead of the
npm-installed `claude.cmd`, looks for `claude-account.json` in the **current
directory only** (no parent walk), and sets `$env:CLAUDE_CONFIG_DIR` for the child
process before invoking the real binary. Each non-personal account lives at
`%USERPROFILE%\.claude-accounts\<name>\`.

If `CLAUDE_CONFIG_DIR` is already set in your environment, the shim prints a
notice to stderr and forwards the call without modification — escape hatch for
manual debugging.

## Uninstall

```powershell
.\uninstall.ps1
```

This removes the marker block from `$PROFILE`. Profile directories under
`~\.claude-accounts\` are left alone — `Remove-Item -Recurse -Force ~\.claude-accounts`
to wipe credentials manually.

## Manual smoke test

After install:

1. `claude` outside any project — uses personal. Confirm with `claude-switch current`
   ("personal — no claude-account.json").
2. `cd` into a folder with `{ "account": "work" }` — `claude-switch current` prints
   "work — from .\claude-account.json". `claude` runs against the work creds.
3. Verify `~\.claude\.credentials.json` and `~\.claude-accounts\work\.credentials.json`
   are different files.

## Requirements

- Windows 10 or 11
- PowerShell 7+ (run `pwsh`, not Windows PowerShell 5.1)
- A working `claude` on `PATH` (typically installed via `npm i -g @anthropic-ai/claude-code`)
````

- [ ] **Step 2: Commit**

```powershell
git add README.md
git commit -m "docs: README with install/usage/smoke-test"
```

---

## Task 15: Verify environment-variable name and run full suite

Spec called out one open verification item: confirm Claude Code's installed CLI uses `CLAUDE_CONFIG_DIR` to override the config home. If the variable is named differently in this user's installed version, swap it in `bin\Invoke-ClaudeShim.ps1`, `bin\claude-switch.ps1` (the `add` subcommand), and `lib\Resolve.psm1` (the `PresetConfigDir` parameter is just an internal name, but the env var read in the shim is what matters).

- [ ] **Step 1: Verify the env var name**

Run any of:

```powershell
claude --help
claude config --help
Get-Command claude | Select-Object Source        # then inspect the .cmd / package
```

Look for the documented override (most likely `CLAUDE_CONFIG_DIR`). Confirm by setting it to a temp dir and observing that a fresh `claude` writes its credentials there.

If the installed version uses a different name (e.g., `CLAUDE_HOME`), do a global rename in:
- `bin\Invoke-ClaudeShim.ps1` (the `$env:CLAUDE_CONFIG_DIR` read)
- `bin\claude-switch.ps1` (the `add` subcommand sets it before launching)
- All test files

- [ ] **Step 2: Run the full Pester suite**

```powershell
Invoke-Pester
```

Expected output: a single `Tests Passed` line with the total count (10 + 11 + 7 + ~15 + 4 = ~47 tests). Anything failing → fix before continuing.

- [ ] **Step 3: Manual smoke test on the user's machine**

Follow the README "Manual smoke test" section start to finish.

- [ ] **Step 4: Final commit (if Task 15 caused any changes)**

```powershell
git status
# if dirty:
git add -A
git commit -m "chore: verify CLAUDE_CONFIG_DIR + final pass"
```
