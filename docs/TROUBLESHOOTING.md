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

## "Usage unavailable" in the account dropdown

Switcheroo shows each account row's remaining five-hour and weekly allowance when it can. If a usage row shows `Usage unavailable`, hover it for a hint:

- **Sign-in may have expired** - the saved access token was rejected by the usage endpoint. Make the account active and run `codex login` to refresh its saved snapshot, or use "Import logged-in account" after logging in.
- **Could not reach the usage service (offline?)** - no network connection or the endpoint timed out. Usage will retry the next time the menu is opened.
- **Usage service is busy or unavailable right now** - the endpoint returned an error or a rate-limit response. Retry shortly.
- **Unexpected usage response** - the endpoint's response shape changed or was malformed. The account itself is unaffected; switching still works.

A usage failure only affects that account's row; the account itself, the other rows, and switching are unaffected, and a failure never changes or deletes your saved credentials.

## “I switched accounts but Pi still acts like the old account”

Switcheroo writes Pi’s `openai-codex` credential during a switch.

> [!IMPORTANT]
> Pi 0.83.x reads its auth file once when the process starts, so restart Pi after switching. Pi 0.84+ detects external auth-file changes automatically on the next credential read; a restart is only needed for a session that is already open.

Try:

- Quit and restart `pi` (`/logout` is not needed) if you are on Pi 0.83.x or have an already-open session
- If Pi still shows the old account after a restart, check the configured Pi auth file (`$PI_CODING_AGENT_DIR/auth.json`, or `~/.pi/agent/auth.json` when the variable is unset): it should have an `openai-codex` entry. If it does not, switch accounts again in Switcheroo.

## “Switch fails with a Pi sync error”

A switch updates both `~/.codex/auth.json` and the configured Pi auth file in one crash-safe transaction. If Pi’s file cannot be read, is not a valid JSON object, the Codex snapshot cannot be converted, or two targets resolve to the same file, the switch fails as a whole and nothing is changed. This is intentional: it prevents the two files from drifting apart.

Fixes to try:

1. Check the error message for the offending path (token contents never appear).
2. If the configured Pi auth file was hand-edited or truncated, repair it or remove it - Switcheroo recreates it with user-only permissions on the next switch.
3. If the error mentions a rollback failure or a leftover transaction journal (`~/Library/Application Support/Switcheroo/state/transaction.json`), one of the auth files could not be restored to its previous state; fix or remove the affected file and switch again, or delete the journal after confirming the files are consistent.

## “Switcheroo won’t start after a crash”

A switch interrupted by a crash (power loss, force quit mid-switch) leaves a transaction journal. On the next launch Switcheroo automatically rolls the switch back or completes it.

If the journal is unreadable, the app reports the journal path and stays stopped to avoid guessing. Fix or remove the journal file after confirming the Codex and configured Pi auth files hold the account you expect.

## Reset Switcheroo

1. Quit Switcheroo.
2. Delete config:
   - `~/Library/Application Support/Switcheroo/config.json`
3. Delete Keychain items:
   - Open Keychain Access
   - Search for service `com.switcheroo.codex`
   - Delete the items

This will remove all saved accounts from Switcheroo.
