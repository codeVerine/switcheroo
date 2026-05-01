# Switcheroo

Small macOS menu bar helper for **manual** Codex account failover when one account can't authenticate or the service is erroring (401/5xx/timeouts).

What it does:
- Stores per-account Codex auth snapshots in Keychain.
- Swaps the active `~/.codex/auth.json` atomically when you switch accounts.
- Keeps the active account snapshot updated periodically (best-effort).

What it does not do:
- No automatic switching based on usage limits or quotas.
- No browser/session tricks. Adding an account uses the official `codex login` flow.

Data locations:
- Config: `~/Library/Application Support/Switcheroo/config.json`
- Keychain service: `com.switcheroo.codex` (one item per account id)
- Unified logs: `log stream --predicate 'subsystem == "com.switcheroo"'`

## Build

Note: On this machine, `swift` may not be able to write its default caches. These commands use `/private/tmp` caches and disable SwiftPM sandboxing.

CLI:
- `mkdir -p /private/tmp/switcheroo-swiftpm-cache /private/tmp/switcheroo-swiftpm-config /private/tmp/switcheroo-swiftpm-security /private/tmp/switcheroo-clang-module-cache`
- `CLANG_MODULE_CACHE_PATH=/private/tmp/switcheroo-clang-module-cache swift build --disable-sandbox -c release --product switcheroo --cache-path /private/tmp/switcheroo-swiftpm-cache --config-path /private/tmp/switcheroo-swiftpm-config --security-path /private/tmp/switcheroo-swiftpm-security --manifest-cache local`

Menu bar app (dev run):
- `CLANG_MODULE_CACHE_PATH=/private/tmp/switcheroo-clang-module-cache swift run --disable-sandbox SwitcherooMenuBar --cache-path /private/tmp/switcheroo-swiftpm-cache --config-path /private/tmp/switcheroo-swiftpm-config --security-path /private/tmp/switcheroo-swiftpm-security --manifest-cache local`

Open logs in Console:
- `log stream --predicate 'subsystem == "com.switcheroo"' --style compact`

Bundle a `.app`:
- `./scripts/bundle_app.sh`

## CLI usage

- `./.build/release/switcheroo list`
- `./.build/release/switcheroo add "Work" --set-active`
- `./.build/release/switcheroo switch Work`
- `./.build/release/switcheroo sync`
