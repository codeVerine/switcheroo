# Switcheroo

Switcheroo is a small native macOS menu bar app for managing and switching between your own Codex CLI accounts.

It also includes an optional CLI, but the menu bar app is the primary user experience.

Use case: you personally own multiple Codex accounts and want a local tool that stores each account snapshot safely in Keychain, shows the accounts in one place, and switches the active `~/.codex/auth.json` without manually copying files.

The codebase is split into a layered SwiftPM package:

- `SwitcherooCore` for provider-agnostic orchestration and protocols
- `SwitcherooPresentation` for shared app state/actions
- `SwitcherooCodexProvider` for the built-in Codex adapter
- `SwitcherooMacAdapters` for macOS config/keychain/process integrations
- `SwitcherooDefaultApp` for shared shell wiring

Switcheroo is intentionally simple: it does not manage profiles, browser sessions, quotas, usage limits, or plan selection. It does not call OpenAI APIs. It just snapshots and swaps the active local `auth.json` used by the Codex app/CLI.

Not affiliated with OpenAI.

## Disclaimer

Switcheroo is only intended for individuals managing their own accounts. It is not intended for account sharing, account pooling, credential sharing, or bypassing OpenAI/Codex usage limits, quotas, policies, or terms of service.

If a Codex outage or server-side issue affects the service globally, switching accounts is unlikely to help. Use this tool to organize and switch accounts you rightfully control, and use it at your own risk.

## How It Works (In One Minute)

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

## License

MIT. See [LICENSE](/LICENSE).
