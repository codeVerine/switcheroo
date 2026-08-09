# Usage

Switcheroo is primarily a native macOS menu bar app (`SwitcherooMenuBar`).

It also includes an optional CLI (`switcheroo`) for advanced use and development. Both front-ends call into the same shared app layer (`SwitcherooPresentation` + `SwitcherooCore`), so behavior stays consistent.

> [!WARNING]
> **Disclaimer:** Switcheroo is designed exclusively for individuals who personally own multiple OpenAI/ChatGPT accounts. It is intended to help you manage your own accounts more conveniently.
>
> This tool is **not** intended for sharing accounts between multiple users, circumventing OpenAI's terms of service, account pooling, or credential sharing.
>
> By using this software, you agree that you are the rightful owner of every account you add to the application. The authors are not responsible for misuse or violations of OpenAI's terms of service.

## Menu Bar App

When you open `Switcheroo.app` you won’t see a window. It runs as a menu bar item.

| Control | Behavior |
| --- | --- |
| Refresh | Reloads config and active status from disk, and refreshes the active account's usage if the last result is stale. |
| Import logged-in account | Snapshots the currently logged in provider account from `~/.codex/auth.json`. If that account is already in Switcheroo, the existing snapshot is refreshed instead of duplicated. |
| Add account | Launches the official `codex login` flow in Terminal for a new account. |
| Switch | Makes that account's snapshot the active `~/.codex/auth.json` and immediately loads the new account's usage. |
| Delete | Removes the account entry and deletes the corresponding Keychain item. |

> [!IMPORTANT]
> For Codex CLI and Codex App users, switch accounts, then restart the client for the new account to take effect.

## Usage Display

The account dropdown shows the active account's remaining allowance under its name, for example `5h 58% · 1w 16%` (five-hour and weekly windows). Hover for reset timing. Details:

- **When it loads**: on app launch and whenever the menu is opened, if the last result is older than a minute. After switching accounts it loads immediately for the newly selected account.
- **How it is fetched**: Switcheroo reads the active account's saved `auth.json` snapshot from Keychain, derives a bearer credential in memory, and calls the Codex usage endpoint (same endpoint family the Codex CLI uses). See [Data & Security](/docs/DATA-AND-SECURITY.md).
- **What the numbers mean**: the endpoint reports consumption as a percentage of each window. Switcheroo derives the remaining allowance (`100 − used`, clamped to 0–100) and shows that.
- **Loading**: `Checking usage…` appears briefly while the request is in flight.
- **Unavailable**: if the request fails (offline, sign-in expired, service busy, or an unexpected response), the row shows `Usage unavailable` with a hover hint. The account switch itself is never blocked by a usage failure.
- **Caching**: results are kept in memory for up to one minute; requests are skipped while one is already in flight, so opening the menu repeatedly does not spam the endpoint.

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

Use Switcheroo when you want to:

- Keep multiple personal Codex account snapshots organized in macOS Keychain.
- Switch the active local `~/.codex/auth.json` without manually copying files.
- Import an existing local Codex login or run the official `codex login` flow for another account.
- Refresh stored snapshots when Codex updates the active account’s auth file during normal use.

It is not meant for:

- Bypassing limits, quotas, usage policies, or terms of service.
- Sharing accounts between users.
- Pooling credentials across a team.
- Automatic account switching.
- Running multiple active identities concurrently.

If Codex is unavailable because of a service-wide or server-side issue, switching accounts is unlikely to help.
