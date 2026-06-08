# Switcheroo

[![Release](https://img.shields.io/badge/release-v0.1.2-2F855A)](https://github.com/codeVerine/switcheroo/releases/tag/v0.1.2)
[![CI](https://github.com/codeVerine/switcheroo/actions/workflows/ci.yml/badge.svg)](https://github.com/codeVerine/switcheroo/actions/workflows/ci.yml)
![macOS](https://img.shields.io/badge/macOS-13%2B-111111?logo=apple)
![Swift](https://img.shields.io/badge/Swift-6.2-F05138?logo=swift)
![Storage](https://img.shields.io/badge/storage-Keychain-2F855A)

Native macOS menu bar app for managing and switching between your own Codex accounts.

Switcheroo stores each account's Codex auth snapshot in Keychain and swaps the active `~/.codex/auth.json` from a small menu bar UI. It also ships an optional CLI for scripting and development, but the packaged app is the primary experience.

> [!IMPORTANT]
> For Codex CLI and Codex App users, switch accounts, then restart the client for the new account to take effect.

> [!WARNING]
> Switcheroo is for accounts you personally own. It is not for account sharing, account pooling, credential sharing, or bypassing OpenAI/Codex limits, quotas, policies, or terms of service.

Switcheroo is intentionally simple: it does not manage profiles, browser sessions, quotas, usage limits, or plan selection. It does not call OpenAI APIs. It just snapshots and swaps the active local `auth.json` used by the Codex app/CLI.

Not affiliated with OpenAI.

## Features

| Feature | What it does |
| --- | --- |
| Menu bar switching | Switch the active Codex account from a native macOS menu bar app. |
| Import existing login | Snapshot the account already logged in at `~/.codex/auth.json`. |
| Add account | Launch the official `codex login` flow in Terminal for another account. |
| Keychain storage | Store inactive auth snapshots as generic password items in macOS Keychain. |
| Snapshot refresh | Best-effort sync keeps known account snapshots fresh when Codex updates the active auth file. |
| Optional CLI | Use `list`, `current`, `import-current`, `add`, `switch`, `sync`, and `delete` from Terminal. |

## Boundaries

| Switcheroo does | Switcheroo does not |
| --- | --- |
| Manage local auth snapshots for accounts you control. | Monitor live usage limits or quotas. |
| Replace `~/.codex/auth.json` when you switch. | Refresh tokens itself. |
| Use local parsing for display metadata such as expiry. | Call OpenAI APIs. |
| Help avoid manual auth-file copying. | Work around service-wide Codex outages. |

## How It Works

1. Each account’s Codex `auth.json` is stored as an opaque blob in macOS Keychain.
2. “Switch” replaces the active `~/.codex/auth.json` atomically with the chosen snapshot.
3. Best-effort sync keeps known account snapshots up to date when the current `auth.json` matches an existing account. The menu bar app polls only near token refresh time; the CLI syncs once per command.

Docs:
- [Usage](/docs/USAGE.md)
- [Data & Security](/docs/DATA-AND-SECURITY.md)
- [Troubleshooting](/docs/TROUBLESHOOTING.md)
- [Architecture](/docs/ARCHITECTURE.md)
- [Development](/docs/DEVELOPMENT.md)

## Requirements

- macOS 13 (Ventura) or later
- `codex` CLI installed and working in your shell

## Install

This repo is release-artifact first. The recommended install path is the packaged app from GitHub Releases.

1. Download the latest `Switcheroo-<version>-macos-arm64.dmg` from [Releases](https://github.com/codeVerine/switcheroo/releases).
2. Open the DMG and copy `Switcheroo.app` to `/Applications`.
3. Launch `Switcheroo.app`; it runs as a menu bar item.

The optional CLI artifact is also available as `switcheroo-<version>-macos-arm64.tar.gz`.

## Build From Source

Run the menu bar app in development:
```bash
swift run SwitcherooMenuBar
```

Build the menu bar `.app` bundle:
```bash
./scripts/bundle_app.sh
open dist/Switcheroo.app
```

Build CLI (optional):
```bash
swift build -c release --product switcheroo
./.build/release/switcheroo list
```

Note: `dist/` is in `.gitignore` (it’s a local build artifact).

## GitHub Actions

- `CI` runs on pushes to `main` and pull requests.
- `Release` runs on `v*` tags and publishes:
  - `Switcheroo-<version>-macos-arm64.dmg`
  - `switcheroo-<version>-macos-arm64.tar.gz` (optional CLI)
- Release notes are generated automatically from git history at publish time.

## Data Locations

- Config: `~/Library/Application Support/Switcheroo/config.json`
- Keychain service: `com.switcheroo.codex` (one generic password item per account id)
- Codex active auth file (default): `~/.codex/auth.json` (Switcheroo swaps this)
- Logs: `log stream --predicate 'subsystem == "com.switcheroo"' --style compact`

## Package Layout

| Target | Role |
| --- | --- |
| `SwitcherooCore` | Provider-agnostic orchestration and protocols. |
| `SwitcherooPresentation` | Shared app state and actions. |
| `SwitcherooCodexProvider` | Built-in Codex adapter. |
| `SwitcherooMacAdapters` | macOS config, Keychain, and process integrations. |
| `SwitcherooDefaultApp` | Shared shell wiring. |
| `SwitcherooMenuBar` | Native macOS menu bar app. |
| `switcheroo` | Optional CLI frontend. |

## License

MIT. See [LICENSE](/LICENSE).
