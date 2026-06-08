# Troubleshooting

## “Switcheroo.app does nothing”

Switcheroo is a menu bar app. On launch it does not open a window and it does not show a Dock icon.

Look for the menu bar icon (SF Symbol: `arrow.triangle.2.circlepath`) near the clock.

If you still don’t see it, check logs:

```bash
log stream --predicate 'subsystem == "com.switcheroo"' --style compact
```

## “Login in Terminal” opens Terminal and then nothing happens

Switcheroo launches:

```bash
export CODEX_HOME="..."; codex login
```

Checks:

1. Confirm `codex` is on your PATH in Terminal:
   ```bash
   which codex
   codex --version
   ```
2. If your shell customizations differ between app-launched Terminal and your normal Terminal, ensure `codex` is available in a login shell (`zsh -lc`).

## “Keychain write failed: -34018”

`-34018` is `errSecMissingEntitlement`, commonly seen when a binary is unsigned, improperly signed, or running without Keychain access in some contexts.

Switcheroo’s `dist/Switcheroo.app` bundle script uses ad-hoc signing (`codesign --sign -`).

Fixes to try:

1. Rebuild the app bundle:
   ```bash
   ./scripts/bundle_app.sh
   ```
2. If you moved the app, rebuild after the move (so the bundled binary and signature match).
3. If you are building your own signed distribution, ensure the app is properly signed (and consider notarization).

## “I switched accounts but Codex still acts like the old account”

Switcheroo swaps the auth file on disk. Existing processes may cache auth in memory.

> [!IMPORTANT]
> For Codex CLI and Codex App users, switch accounts, then restart the client for the new account to take effect.

Try:

- Quit/restart the Codex app
- Re-run your Codex CLI command in a new shell

## Reset Switcheroo

1. Quit Switcheroo.
2. Delete config:
   - `~/Library/Application Support/Switcheroo/config.json`
3. Delete Keychain items:
   - Open Keychain Access
   - Search for service `com.switcheroo.codex`
   - Delete the items

This will remove all saved accounts from Switcheroo.
