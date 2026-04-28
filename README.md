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
   ("personal (~\.claude) — no claude-account.json").
2. `cd` into a folder with `{ "account": "work" }` — `claude-switch current` prints
   "work — from .\claude-account.json". `claude` runs against the work creds.
3. Verify `~\.claude\.credentials.json` and `~\.claude-accounts\work\.credentials.json`
   are different files.

## Requirements

- Windows 10 or 11
- PowerShell 7+ (run `pwsh`, not Windows PowerShell 5.1)
- A working `claude` on `PATH` (typically installed via `npm i -g @anthropic-ai/claude-code`)
