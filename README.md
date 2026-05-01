# Switcheroo

Switcheroo is a small macOS menu bar app + CLI for **manual** Codex account failover.

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
3. A background “Sync” keeps the currently-active snapshot up to date (best-effort) by re-saving the current `auth.json` back into Keychain.

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

Build CLI:
```bash
swift build -c release --product switcheroo
./.build/release/switcheroo list
```

Run the menu bar app in development:
```bash
swift run SwitcherooMenuBar
```

Build the menu bar `.app` bundle:
```bash
./scripts/bundle_app.sh
open dist/Switcheroo.app
```

Note: `dist/` is in `.gitignore` (it’s a local build artifact).

## Data Locations

- Config: `~/Library/Application Support/Switcheroo/config.json`
- Keychain service: `com.switcheroo.codex` (one generic password item per account id)
- Codex active auth file (default): `~/.codex/auth.json` (Switcheroo swaps this)
- Logs: `log stream --predicate 'subsystem == "com.switcheroo"' --style compact`

## License

MIT. See [LICENSE](/LICENSE).
