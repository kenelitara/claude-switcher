# claude-switcher — `--profile` flag for `claude`

**Date:** 2026-10-03
**Platform:** Windows 11, PowerShell 7+
**Status:** Approved

## Problem

Today `claude` routing is driven entirely by `claude-account.json` in the current
directory (see the base design, `2026-04-28-claude-switcher-design.md`). To run a
one-off invocation against a *different* account — or to escape a project that is
pinned to a work account — the user must manually pre-set `$env:CLAUDE_CONFIG_DIR`,
which is session-global and easy to leave stale.

We want a per-invocation override: `claude --profile <name>` picks the account for
that single call, ignoring `claude-account.json`.

## Solution Overview

Add a `--profile` flag parsed by the shim. It takes precedence over every existing
resolution source, including a preset `CLAUDE_CONFIG_DIR`. Two reserved sentinel
names — `personal` and `none` — force the personal account at `~\.claude`.

Three touched units, following the repo's one-concern-per-module layout:

1. **`lib\Args.psm1`** (new) — pure argv parsing. Extracts/validates `--profile`,
   returns the remaining argv for forwarding.
2. **`lib\Resolve.psm1`** — `Resolve-ProfileForCwd` gains an `-ExplicitProfile`
   parameter and a new highest-precedence branch.
3. **`bin\Invoke-ClaudeShim.ps1`** — wires the two together: parse, resolve, set or
   clear `CLAUDE_CONFIG_DIR`, forward the stripped argv.

## Decisions

| Question | Decision |
|---|---|
| Invocation form | `claude --profile <name>` (flag on `claude`) |
| Short alias | **None.** `-p` is Claude Code's print/headless flag; an alias would shadow it. |
| Force personal | Reserved sentinel names `personal` and `none` |
| Precedence vs preset `CLAUDE_CONFIG_DIR` | `--profile` wins (explicit flag beats ambient env) |

## Component Design

### `lib\Args.psm1` → `Split-ProfileFlag`

```
Split-ProfileFlag -Args [string[]]
  -> [pscustomobject]@{ Args = [string[]]; Profile = [string]|$null; Error = [string]|$null }
```

- Accepts both `--profile <name>` and `--profile=<name>`.
- Removes the matched tokens from `Args`; the returned `Args` is what gets forwarded
  to the real binary.
- Parsing stops at the first bare `--`; that token and everything after it are
  forwarded verbatim (a literal `--profile` passed after `--` is never consumed).
- `Error` (non-null) when:
  - `--profile` is given with no following value, or with an empty/whitespace value.
  - `--profile` appears more than once (ambiguous — error rather than silent last-wins).
  - On error, `Args` and `Profile` are both `$null` (the shim exits before using them).
- Matching is case-insensitive and trimmed, consistent with Windows path/profile lookup
  and PowerShell's default `-eq` semantics.
- Pure function: no filesystem or environment access. Independently unit-testable.

### `lib\Resolve.psm1` → `Resolve-ProfileForCwd -ExplicitProfile`

New parameter `-ExplicitProfile [string]` (optional; `$null`/absent = no override).

Resolution order becomes:

1. **Explicit override** (new, highest precedence). If `-ExplicitProfile` is non-empty:
   - Name is `personal` or `none` → `Source = 'explicit-personal'`, `ProfileDir = $null`,
     `Reason = "personal (~\.claude) — forced by --profile <name>"`.
   - Name exists under `ProfilesRoot` → `Source = 'explicit'`,
     `ProfileDir = <root>\<name>`, `Reason = "<name> — from --profile"`.
   - Otherwise → throw `claude-switcher: account '<name>' is not configured. Run: claude-switch add <name>`.
   - This branch is evaluated **before** the preset-`CLAUDE_CONFIG_DIR` (`env-bypass`)
     check, so `--profile` overrides a stale env var.
2. `env-bypass` (preset `CLAUDE_CONFIG_DIR`, no explicit override) — unchanged.
3. `project` (`.\claude-account.json`) — unchanged.
4. `default` (`.switcher.json`) — unchanged.
5. `personal` — unchanged.

### `bin\Invoke-ClaudeShim.ps1`

1. Import `Args.psm1` alongside the existing modules.
2. `$split = Split-ProfileFlag -Args $ClaudeArgs`. If `$split.Error` → write to stderr,
   `exit 1` (no launch).
3. Call `Resolve-ProfileForCwd ... -ExplicitProfile $split.Profile`.
4. Apply the decision:
   - `Source = 'explicit'` → `$env:CLAUDE_CONFIG_DIR = $decision.ProfileDir`.
   - `Source = 'explicit-personal'` → `Remove-Item env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue`
     (clear any preset value so the child falls back to `~\.claude`).
   - `env-bypass` → existing stderr notice, forward unchanged.
   - `project`/`default` → set `$env:CLAUDE_CONFIG_DIR = $decision.ProfileDir` (existing behavior).
   - `personal` → leave env unset (existing behavior).
5. `& $real @($split.Args)` — forward the flag-stripped argv.

## Error Handling

| Condition | Behavior |
|---|---|
| `--profile` with no/empty value | stderr usage error, exit 1, no launch |
| `--profile` given twice | stderr ambiguity error, exit 1, no launch |
| Unknown profile name | existing `account '<name>' is not configured. Run: claude-switch add <name>` |
| `--profile personal` / `none` | no error; forces `~\.claude`, ignores project file |
| `--profile` after a bare `--` | not parsed; forwarded verbatim |

## Testing Strategy

**Unit — `tests\Args.Tests.ps1` (new):**
- `--profile work` → `Profile='work'`, `Args` without the flag.
- `--profile=work` → same.
- No flag → `Profile=$null`, `Args` unchanged.
- `--profile` at end with no value → `Error`.
- Duplicate `--profile` → `Error`.
- `-- --profile work` → `Profile=$null`, tokens forwarded verbatim.
- Surrounding args (`--resume`, prompt text) preserved in `Args`.

**Unit — `tests\Resolve.Tests.ps1` (extend):**
- `-ExplicitProfile work` (known) → `Source='explicit'`, correct `ProfileDir`.
- `-ExplicitProfile ghost` → throws `*not configured*`.
- `-ExplicitProfile personal` and `none` → `Source='explicit-personal'`, `ProfileDir` null.
- Explicit override beats a preset `CLAUDE_CONFIG_DIR` (`Source='explicit'`, not `'env-bypass'`).
- Explicit override beats a `claude-account.json` naming a different profile.

**Integration — `tests\Integration.Tests.ps1` (extend, fake `claude.cmd` probe):**
- `--profile work` → probe shows `env=<root>\work` and `args` without `--profile`.
- `--profile personal` with a project file present → probe shows empty `env`.
- `--profile work` with a preset `CLAUDE_CONFIG_DIR` → probe shows `env=<root>\work`.
- `--profile ghost` → stderr mentions `not configured`, exit non-zero.
- `--profile` with no value → stderr usage error, exit non-zero.

**Docs — `README.md`:** add `claude --profile <name>` to the usage section, and note
that a profile literally named `personal` or `none` is unreachable via `--profile`.

## Out of Scope (YAGNI)

- A `claude-switch run <name>` subcommand (flag on `claude` chosen instead).
- A short alias for `--profile`.
- Shell completion / tab-completion for profile names.
- Any change to `claude-switch` subcommands — the CLI still operates on the global
  registry and never consults `claude-account.json` (unchanged invariant).

## Known Trade-off

Because `personal` and `none` are reserved sentinels, a profile literally named
`personal` or `none` cannot be selected via `--profile` (the sentinel wins). Documented
in the README rather than special-cased.
