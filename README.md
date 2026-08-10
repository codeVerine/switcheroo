<p align="center">
  <img src="Assets/AppIcon.png" alt="Switcheroo app icon" width="120" height="120">
</p>

<h1 align="center">Switcheroo</h1>

[![Release](https://img.shields.io/github/v/release/codeVerine/switcheroo?label=release)](https://github.com/codeVerine/switcheroo/releases)
[![CI](https://github.com/codeVerine/switcheroo/actions/workflows/ci.yml/badge.svg)](https://github.com/codeVerine/switcheroo/actions/workflows/ci.yml)
![macOS](https://img.shields.io/badge/macOS-13%2B-111111?logo=apple)
![Swift](https://img.shields.io/badge/Swift-6.2-F05138?logo=swift)
![Storage](https://img.shields.io/badge/storage-Keychain-2F855A)

Native macOS menu bar app for managing and switching between your own Codex accounts.

Switcheroo stores each account's Codex auth snapshot in Keychain and swaps the active `~/.codex/auth.json` from a small menu bar UI. When you switch, it also synchronizes the same account into Pi's `openai-codex` login, so no second `/logout` and `/login` flow is needed. It also ships an optional CLI for scripting and development, but the packaged app is the primary experience.

> [!IMPORTANT]
> For Codex CLI and Codex App users, switch accounts, then restart the client for the new account to take effect.

For Pi reload behavior after a switch, see [Troubleshooting](/docs/TROUBLESHOOTING.md).

Switcheroo is intentionally simple: it does not manage profiles, browser sessions, quotas, usage limits, or plan selection. It does not call model, platform, or Pi APIs. During usage refreshes (including menu opens and account switches), it makes one read-only usage request per saved account to the Codex usage endpoint (see [Data & Security](/docs/DATA-AND-SECURITY.md)). It snapshots and swaps the active local `auth.json` used by the Codex app/CLI, and mirrors that account into Pi's auth file.

Not affiliated with OpenAI.

## Screenshots

<p align="center">
  <img src="Assets/Screenshots/empty-state.png" alt="Switcheroo empty state" width="360">
  <img src="Assets/Screenshots/account-list.png" alt="Switcheroo account list" width="360">
</p>

## Install

This repo is release-artifact first. The recommended install path is the packaged app from GitHub Releases.

1. Download the latest `Switcheroo-<version>-macos-arm64.dmg` from [Releases](https://github.com/codeVerine/switcheroo/releases).
2. Open the DMG and copy `Switcheroo.app` to `/Applications`.
3. Launch `Switcheroo.app`; it runs as a menu bar item.

### Opening on macOS

Switcheroo release builds are unsigned. If macOS blocks the first launch, open **System Settings → Privacy & Security**, find the Switcheroo security message, click **Open Anyway**, then confirm **Open Anyway** in the dialog.

<p align="center">
  <img src="Assets/Screenshots/not-opened.png" alt="macOS Gatekeeper warning that Switcheroo was not opened" width="420">
  <br>
  <br>
  <img src="Assets/Screenshots/open-anyway.png" alt="macOS Privacy & Security Open Anyway prompt for Switcheroo" width="520">
</p>

The optional CLI artifact is also available as `switcheroo-<version>-macos-arm64.tar.gz`.

> [!WARNING]
> This project uses OAuth account credentials and is intended for personal development use.
>
> By using this package, you acknowledge:
>
> - This is an independent open-source project, not an official OpenAI product.
> - You are responsible for your own usage and policy compliance.
> - The authors are not responsible for misuse or violations of OpenAI's terms of service.
> - For production or commercial workloads, use the OpenAI Platform API.

## Features

| Feature | What it does |
| --- | --- |
| Menu bar switching | Switch the active Codex account from a native macOS menu bar app. |
| Pi account sync | A switch also selects the same account for Pi's `openai-codex` entry (default auth file: `~/.pi/agent/auth.json`). |
| Import existing login | Snapshot the account already logged in at `~/.codex/auth.json`. |
| Add account | Launch the official `codex login` flow in Terminal for another account. |
| Keychain storage | Store inactive auth snapshots as generic password items in macOS Keychain. |
| Snapshot refresh | Best-effort sync keeps known account snapshots fresh when Codex updates the active auth file. |
| Usage display | Show every account's remaining five-hour and weekly Codex allowance in the account dropdown, refreshed per row. |
| Optional CLI | Use `list`, `current`, `import-current`, `add`, `switch`, `sync`, and `delete` from Terminal. |

## Boundaries

| Switcheroo does | Switcheroo does not |
| --- | --- |
| Manage local auth snapshots for accounts you control. | Monitor live usage limits in real time or poll them in the background. |
| Replace `~/.codex/auth.json` when you switch. | Refresh tokens itself. |
| Use local parsing for display metadata and auth-target conversion. | Call OpenAI model or platform APIs. |
| Fetch every account's remaining allowance from the read-only Codex usage endpoint, one credential per account. | Share accounts, pool credentials, or bypass terms of service. |
| Mirror the selected account into Pi's auth file on switch. | Work around service-wide Codex outages. |
| Keep account switching local to your Mac. | Run any background sync service. |

## How It Works

1. Each account’s Codex `auth.json` is stored as an opaque blob in macOS Keychain.
2. “Switch” runs one serialized transaction: it replaces the active `~/.codex/auth.json` atomically with the chosen snapshot and synchronizes the same account into Pi’s `openai-codex` entry, preserving Pi’s other providers. A durable journal (user-only permissions) makes crash recovery explicit: an interrupted transaction is rolled back or completed at the next launch, or remains as a recovery record if concurrent changes prevent completion.
3. Best-effort sync keeps known account snapshots up to date when the current `auth.json` matches an existing account. The menu bar app polls only near token refresh time; the CLI syncs once per command.
4. Usage display: the menu bar app reads each saved account's snapshot from Keychain, derives a bearer credential from it, and calls the read-only Codex usage endpoint for that account's five-hour and weekly remaining allowance on its usage refreshes. Every row is fetched with its own credential; results are kept in memory only, keyed by account, updated live in the open dropdown, and never persisted.

If Pi’s auth file is malformed or cannot be converted, the switch fails as a whole and reports an error. Crash recovery is journaled; see [Data & Security](/docs/DATA-AND-SECURITY.md) for the recovery contract. Token contents never appear in logs or errors.

Docs:
- [Usage](/docs/USAGE.md)
- [Data & Security](/docs/DATA-AND-SECURITY.md)
- [Troubleshooting](/docs/TROUBLESHOOTING.md)
- [Architecture](/docs/ARCHITECTURE.md)
- [Development](/docs/DEVELOPMENT.md)

## Requirements

- macOS 13 (Ventura) or later
- `codex` CLI installed and working in your shell

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
- Pi auth file (default): `~/.pi/agent/auth.json` (Switcheroo updates its `openai-codex` entry on switch)
- Transaction state: `~/Library/Application Support/Switcheroo/state/` (crash journal + switch lock, user-only permissions)
- Logs: `log stream --predicate 'subsystem == "com.switcheroo"' --style compact`

## Package Layout

| Target | Role |
| --- | --- |
| `SwitcherooCore` | Provider-agnostic orchestration, auth-target adapter contract, and protocols. |
| `SwitcherooPresentation` | Shared app state and actions. |
| `SwitcherooCodexProvider` | Built-in Codex provider and auth target (whole-file swap). |
| `SwitcherooPiAdapter` | Built-in Pi auth target (syncs `openai-codex` on switch). |
| `SwitcherooMacAdapters` | macOS config, Keychain, and process integrations. |
| `SwitcherooDefaultApp` | Shared shell wiring. |
| `SwitcherooMenuBar` | Native macOS menu bar app. |
| `switcheroo` | Optional CLI frontend. |

## License

MIT. See [LICENSE](/LICENSE).
