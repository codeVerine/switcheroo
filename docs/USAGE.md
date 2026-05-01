# Usage

Switcheroo supports two front-ends:

- Menu bar app: `SwitcherooMenuBar` (built into `dist/Switcheroo.app`)
- CLI: `switcheroo`

The underlying behavior is the same: Switcheroo stores per-account snapshots of Codex `auth.json`, and swaps the active `auth.json` when you switch accounts. The current build ships with a Codex provider, but the app is structured so other providers can be added in code later.

## Menu Bar App

When you open `Switcheroo.app` you won’t see a window. It runs as a menu bar item.

Controls:

- Refresh: reloads config + active status from disk.
- Add Account:
  - Login in Terminal: launches the official `codex login` flow in Terminal for a new account.
  - Import Current: snapshots your currently-active `~/.codex/auth.json` into Switcheroo under the given name.
- Accounts list:
  - Switch: makes that account’s snapshot the active `~/.codex/auth.json`.
  - Delete: removes the account entry and deletes the corresponding Keychain item.
- Sync Now: snapshots the *current* active `~/.codex/auth.json` back into Keychain for the active account.

Important behavior: switching updates `~/.codex/auth.json` on disk, but running processes may need to be restarted to pick up the new auth.

Background behavior:

- The menu bar app runs a best-effort sync on a timer (currently every ~15 seconds) to keep the active account snapshot up to date.

## CLI

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

- `switcheroo add` runs `codex login` with a per-account provider home so Codex writes a fresh `auth.json` for that login. Switcheroo then imports that `auth.json` snapshot and deletes the temporary provider home directory.
- `switcheroo sync` is best-effort; it does not “refresh” tokens itself. It only re-saves whatever Codex has currently written to `auth.json`.

## When To Use Switcheroo

Switcheroo is meant for “account down” failover:

- Authentication failures (`401`)
- Service errors (`5xx`)
- Timeouts

It is not meant for:

- Avoiding limits/quotas
- Automatic switching
- Running multiple active identities concurrently
