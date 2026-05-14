# Switcheroo

Switcheroo is a small native macOS menu bar app for **manual** Codex account failover.

It also includes an optional CLI, but the menu bar app is the primary user experience.

Use case: you have multiple legit Codex accounts already authenticated locally, and you want a fast toggle when one account hits an auth/service outage (401/5xx/timeouts).

The codebase is split into a layered SwiftPM package:

- `SwitcherooCore` for provider-agnostic orchestration and protocols
- `SwitcherooPresentation` for shared app state/actions
- `SwitcherooCodexProvider` for the built-in Codex adapter
- `SwitcherooMacAdapters` for macOS config/keychain/process integrations
- `SwitcherooDefaultApp` for shared shell wiring

Switcheroo is intentionally simple: it does not manage profiles, browser sessions, quotas, or plan selection. It just swaps the active local `auth.json` used by the Codex app/CLI.

Not affiliated with OpenAI.

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

## Build

Right now this repo ships source-first.

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
