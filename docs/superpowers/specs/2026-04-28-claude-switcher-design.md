# claude-switcher — Design

**Date:** 2026-04-28
**Platform:** Windows 11, PowerShell 7+ (used inside VS Code / Windsurf / Antigravity terminals)
**Status:** Approved (pending user spec review)

## Problem

The user runs multiple Claude Code accounts on the same Windows machine. Today there is one set of credentials at `%USERPROFILE%\.claude\.credentials.json` and a single shared history, so switching accounts requires logout/login churn and bleeds conversations between accounts. The user wants per-project-folder account selection: drop a `claude-account.json` in a project root, and `claude` invocations from that folder use the matching account. Folders without the file fall back to a configured default.

## Solution Overview

Three PowerShell components, all shipped from this repo:

1. **`bin\Invoke-ClaudeShim.ps1`** — routing logic. Reads `./claude-account.json` from `$PWD` (exact CWD only, no parent walk), resolves to a profile directory, sets `$env:CLAUDE_CONFIG_DIR` for the child process, then forwards all arguments to the real `claude.cmd`.
2. **`bin\claude-switch.ps1`** — management CLI. Subcommands for adding, listing, removing, inspecting, and defaulting profiles.
3. **`install.ps1`** — appends a marker block to the user's PowerShell `$PROFILE` that defines `claude` and `claude-switch` functions. The function-in-profile approach intercepts the bare word `claude` ahead of the npm-installed binary without modifying `PATH`.

Each non-default account gets an isolated profile directory at `%USERPROFILE%\.claude-accounts\<name>\`. The **default account is the user's personal account, which lives at the original `%USERPROFILE%\.claude\`** and is untouched by the installer. Whenever a working directory has no `claude-account.json`, `claude` runs against the personal account exactly as it does today. Account isolation is achieved entirely via Claude Code's `CLAUDE_CONFIG_DIR` environment variable — the shim sets it for the child `claude.cmd` invocation and nothing else; no symlink swapping, no credential copying.

## Architecture

### Directory layout

```
%USERPROFILE%\.claude\                          # personal account = the fallback when
                                                #   no claude-account.json is present
                                                #   (existing dir, untouched by installer)
%USERPROFILE%\.claude-accounts\
    .switcher.json                              # { "default": "<name>" | null }
                                                #   null means fall back to ~\.claude
    work\                                       # full ~/.claude-style dir for "work"
        .credentials.json
        settings.json
        ...
    client-x\
        .credentials.json
        ...
```

The set of known profiles is determined by enumerating subdirectories of `~\.claude-accounts\` (excluding `.switcher.json` and any dotfile). This keeps the registry self-healing: copy a folder in or out and the CLI reflects reality.

### `claude-account.json` schema

```json
{ "account": "work" }
```

Single required field: `account` (string, non-empty). Unknown extra keys are ignored for forward compatibility. No env-var overrides, no model overrides — those concerns live in the per-account `settings.json` inside the profile dir.

The file is intended to be committed to source control. It contains no secrets — only an account name that points at a local profile.

### Routing rules (in the shim, on `claude` invocation)

The shim runs before the real `claude.cmd` and decides what to set `$env:CLAUDE_CONFIG_DIR` to:

1. If `$env:CLAUDE_CONFIG_DIR` is **already set** in the calling environment — respect it, print one line to stderr (`claude-switcher: CLAUDE_CONFIG_DIR already set, bypassing`), and forward to the real `claude` unchanged. This is the manual-override escape hatch.
2. Else if `./claude-account.json` exists in `$PWD`:
   - Parse it as UTF-8 JSON. Malformed → hard-fail with parser message.
   - If `account` is missing or empty → hard-fail with schema message.
   - If the named profile exists under `~\.claude-accounts\` → set `CLAUDE_CONFIG_DIR` to that path and launch.
   - If the named profile does not exist → hard-fail with `claude-switcher: account '<name>' is not configured. Run: claude-switch add <name>`.
3. Else (no `claude-account.json` in CWD): fall back to the **personal account at `~\.claude`** by leaving `CLAUDE_CONFIG_DIR` unset, which is what `claude` uses by default. If `.switcher.json` has a non-null `default` (set via `claude-switch default <name>`), that named profile takes precedence over personal — the field exists for users who want a non-personal fallback, but the out-of-the-box value is `null` and the personal account is the fallback.

### Real-binary discovery

The `claude` function in `$PROFILE` must invoke the real `claude.cmd` (typically `%APPDATA%\npm\claude.cmd`) without recursing into itself. The shim resolves it once per session via `Get-Command claude -CommandType Application -All | Select-Object -First 1` and caches the result in a script-scope variable. If no `Application`-type command is found → hard-fail with `claude-switcher: real 'claude' executable not found on PATH`.

The PowerShell function-name lookup beats `PATH` for the bare word `claude`, but `Get-Command -CommandType Application` skips functions, so the shim resolves the real binary cleanly.

### Profile resolution failure modes

| Condition | Behavior |
|---|---|
| Malformed `claude-account.json` | Hard-fail, exit non-zero, print parser error |
| `account` field missing/empty | Hard-fail with schema error |
| Account name unknown | Hard-fail with `claude-switch add <name>` hint |
| Profile dir exists but lacks `.credentials.json` | Warn, launch anyway — user enters `/login` flow inside that profile, which is the recovery path |
| `CLAUDE_CONFIG_DIR` already set | Bypass routing, print notice, forward unchanged |
| Real `claude` binary not on `PATH` | Hard-fail with not-found error |

## Management CLI: `claude-switch`

```
claude-switch add <name>          Create %USERPROFILE%\.claude-accounts\<name>\,
                                  set CLAUDE_CONFIG_DIR to it, then launch the real
                                  `claude` so the user can authenticate into the new
                                  profile (typing `/login` at the REPL, or running
                                  whatever the installed CLI's login subcommand is —
                                  the switcher does not assume a specific login path,
                                  it only guarantees the env points at the new dir).
claude-switch list                List all profiles. Always shows the personal
                                  account (~\.claude) as the first entry, marked as
                                  "personal (fallback)". Marks the configured default
                                  if .switcher.json overrides personal, and marks the
                                  profile that resolves in the current CWD when a
                                  claude-account.json is present.
claude-switch remove <name>       Delete the profile directory. Prompts for
                                  confirmation; refuses to remove the active default
                                  unless --force is passed.
claude-switch current             Print which profile would be used in the current
                                  directory and why. Examples:
                                      "work — from .\claude-account.json"
                                      "personal (~\.claude) — no claude-account.json"
                                      "client-x — configured default override"
claude-switch default <name>      Write { "default": "<name>" } to
                                  %USERPROFILE%\.claude-accounts\.switcher.json.
                                  Validates that <name> exists.
claude-switch default --reset     Clear the override so the personal account
                                  (~\.claude) is the fallback again. Sets `default`
                                  to null in .switcher.json.
claude-switch where <name>        Print the absolute path of the profile dir
                                  (useful for piping into Explorer or rm).
claude-switch init [name]         Write a claude-account.json into CWD with the
                                  given account name. Refuses to overwrite an
                                  existing file unless --force.
claude-switch help                Print usage.
```

The `claude-switch` CLI **never** consults the per-project `claude-account.json` — it always operates on the global registry. This avoids the confusing case where `claude-switch list` output depends on `cd` location.

## Install / Uninstall

### `install.ps1`

1. Refuse to run on PowerShell < 7 (`$PSVersionTable.PSVersion.Major -lt 7`).
2. Resolve the user's `$PROFILE` path. Create the file and any missing parent directories if necessary.
3. Append a marker block to `$PROFILE`. The literal string `<INSTALL_ROOT>` below is replaced at install time with the absolute path of `$PSScriptRoot` (the directory of `install.ps1`), so the repo can live anywhere on disk:
   ```powershell
   # >>> claude-switcher >>>
   . '<INSTALL_ROOT>\bin\profile-snippet.ps1'
   # <<< claude-switcher <<<
   ```
   For this user's machine the rendered block would dot-source `D:\Workspace Elitara\claude-switcher\bin\profile-snippet.ps1`.
4. If the marker block is already present, replace it (idempotent re-install).
5. Create `%USERPROFILE%\.claude-accounts\` if missing.
6. Print next steps: reload `$PROFILE` (`. $PROFILE`), then `claude-switch add <name>` to authenticate the first non-default account.

### `bin\profile-snippet.ps1`

Defines two functions in the user's session:

- `claude` — calls `Invoke-ClaudeShim.ps1` with `$args`, which sets `CLAUDE_CONFIG_DIR` and invokes the real `claude.cmd`.
- `claude-switch` — calls `claude-switch.ps1` with `$args`.

Both functions resolve sibling script paths from a fixed root computed at install time and stored as a script-scope constant in the snippet, so they don't depend on `$PSScriptRoot` (which varies by caller in PowerShell function bodies).

### `uninstall.ps1`

1. Strip the `>>> claude-switcher >>>` ... `<<< claude-switcher <<<` block from `$PROFILE`.
2. Print a notice that profile directories under `~\.claude-accounts\` are left in place. User removes manually if they want creds wiped (`Remove-Item -Recurse ~\.claude-accounts`).

## Security and Concurrency

**Profile directory permissions.** Created with default Windows ACLs inherited from `%USERPROFILE%`. This matches the existing `~\.claude` directory — no extra hardening, no extra exposure. The README documents that credentials live at `~\.claude-accounts\<name>\.credentials.json` so the user can audit.

**Concurrent invocations.** Two terminals launching `claude` from different folders are fully independent — each `CLAUDE_CONFIG_DIR` lives in its own child-process environment. No shared mutable state in the shim, no lock files.

**Encoding.** `claude-account.json` and `.switcher.json` are read as UTF-8 with BOM tolerated. Files written by the CLI are UTF-8 without BOM.

## Testing Strategy

**Unit tests (Pester):**

- `Resolve-Profile` — given `(cwd, env:CLAUDE_CONFIG_DIR, .switcher.json contents, ./claude-account.json contents, accounts dir state)`, returns the right profile path or the right error. Covers all rows of the failure-mode table.
- `claude-switch` subcommand argument parsing and validation.

**Integration tests (Pester, against a real `claude` only when present):**

- `add` flow uses a fake `claude.cmd` that just touches `$env:CLAUDE_CONFIG_DIR\.credentials.json` so the test does not require real OAuth.
- `current` output for each of: project file, no project file with default set, no project file with default reset.

**Manual smoke checklist (in README):**

- Install, reload profile, `claude-switch add work`, log in, run `claude` outside any project — uses default. `cd` into a folder with `{ "account": "work" }` — uses work. Verify `~\.claude\.credentials.json` and `~\.claude-accounts\work\.credentials.json` are distinct files.

## Open Verification Item

Claude Code's environment-variable name for overriding the config home is, to the best of current knowledge, `CLAUDE_CONFIG_DIR`. The implementation plan must verify this against the installed CLI version (e.g., `claude --help`, `claude config --help`, or by inspecting `claude.cmd` / its npm package) before locking the shim's behavior. If the variable is named differently in the user's installed version, swap it in the shim — the rest of the design is unaffected.

## Out of Scope (Explicit YAGNI)

- Walking up parent directories to find `claude-account.json` (user picked exact-CWD only).
- Per-project model or env-var overrides in `claude-account.json` (one field, account name only).
- Cross-shell support — bash, cmd, fish are not supported. PowerShell 7+ only.
- Credential migration tooling. New profiles always start empty and run `/login`.
- A GUI or a system-tray switcher.
