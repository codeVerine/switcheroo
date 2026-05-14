# Usage

Switcheroo is primarily a native macOS menu bar app (`SwitcherooMenuBar`).

It also includes an optional CLI (`switcheroo`) for advanced use and development. Both front-ends call into the same shared app layer (`SwitcherooPresentation` + `SwitcherooCore`), so behavior stays consistent.

## Menu Bar App

When you open `Switcheroo.app` you won’t see a window. It runs as a menu bar item.

Controls:

- Refresh: reloads config + active status from disk.
- Import logged-in account: snapshots the currently logged in provider account from `~/.codex/auth.json`. If that account is already in Switcheroo, the existing snapshot is refreshed instead of creating a duplicate.
- Add account:
  - Login in Terminal: launches the official `codex login` flow in Terminal for a new account.
- Accounts list:
  - Switch: makes that account’s snapshot the active `~/.codex/auth.json`.
  - Delete: removes the account entry and deletes the corresponding Keychain item.

Important behavior: switching updates `~/.codex/auth.json` on disk, but running processes may need to be restarted to pick up the new auth.

Background behavior:

- Switcheroo attempts a best-effort sync from the active `~/.codex/auth.json` into the matching Keychain snapshot when the menu bar app launches and before a switch. The CLI also does this once per command invocation.
- The menu bar app only polls every 15 seconds when the active access token has less than 2 days and 5 minutes left. If the active token expiry cannot be read or matched, the menu bar shows `Re-login required.`.

## CLI (Optional)

Build:

```bash
swift build -c release --product switcheroo
```

Commands:

```bash
./.build/release/switcheroo list
./.build/release/switcheroo current
./.build/release/switcheroo import-current "Personal"
./.build/release/switcheroo add "Work" --set-active
./.build/release/switcheroo switch Work
./.build/release/switcheroo sync
./.build/release/switcheroo delete Work
```

Notes:

- `switcheroo add` runs `codex login` with a per-account provider home so Codex writes a fresh `auth.json` for that login. Switcheroo then imports that snapshot, refreshes an existing matching account if found, and deletes the temporary provider home directory.
- `switcheroo sync` is best-effort; it does not “refresh” tokens itself. It only re-saves the current `auth.json` when it matches an existing Switcheroo account. It will not create accounts in the background.

## When To Use Switcheroo

Switcheroo is meant for “account down” failover:

- Authentication failures (`401`)
- Service errors (`5xx`)
- Timeouts

It is not meant for:

- Avoiding limits/quotas
- Automatic switching
- Running multiple active identities concurrently
