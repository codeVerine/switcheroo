# Data & Security

Switcheroo’s job is to swap the local Codex auth file. That means it necessarily handles sensitive credentials (whatever is in your Codex `auth.json`).

This document explains what is stored, where it is stored, and what Switcheroo does (and does not) try to protect.

## What Switcheroo Stores

1. A config file describing your Switcheroo accounts.
2. For each account, an opaque snapshot of Codex `auth.json` stored in Keychain.

Switcheroo does not attempt to parse, interpret, or modify the contents of `auth.json` beyond copying bytes. If Codex changes the file format, Switcheroo should continue working as long as the file remains a single JSON file that Codex consumes.

Note: the menu-bar UI and account import paths may perform best-effort, local-only parsing of the stored `auth.json` snapshot to show non-sensitive metadata (for example, access token expiry), derive a reasonable default account name, and detect whether an imported account already exists. The usage display additionally reads the access token (and ChatGPT account id) from the snapshot in memory to authenticate one read-only usage request; see “Usage Display Network Calls” below. Switcheroo still stores and swaps the full file as opaque bytes.

## What Is In `auth.json` (Typical)

Switcheroo treats `auth.json` as opaque. For reference only: as of May 1, 2026, the `~/.codex/auth.json` observed on the author’s machine had top-level keys:

- `OPENAI_API_KEY`
- `auth_mode`
- `last_refresh`
- `tokens`

And `tokens` contained:

- `access_token`
- `refresh_token`
- `id_token`
- `account_id`

Notably, it did not contain user identity fields like email or subscription plan name.

Your file may differ depending on Codex version and authentication mode.

## Storage Locations

Config:

- `~/Library/Application Support/Switcheroo/config.json`

Keychain:

- Service: `com.switcheroo.codex`
- Item type: generic password
- One Keychain item per Switcheroo account id
- Value: raw bytes of that account’s `auth.json`

Active Codex auth file:

- Default: `~/.codex/auth.json`
- Switcheroo overwrites this file atomically when you switch accounts.

Pi auth file (auth-target sync):

- Default: `~/.pi/agent/auth.json` (or `$PI_CODING_AGENT_DIR/auth.json` when set, matching Pi’s own resolution)
- When you switch accounts, Switcheroo updates the `openai-codex` entry from the active Codex snapshot and leaves every other provider entry untouched.
- The file (and its parent directory) is created when absent, and is written atomically with user-only permissions (`0o600`, matching Pi’s own writes).

## Pi Synchronization

When you switch accounts, Switcheroo converts the selected account’s Codex snapshot into Pi’s `openai-codex` OAuth credential (access token, refresh token, expiry, and account id) and merges it into Pi’s auth file. The conversion is local and in-memory: Switcheroo does not persist parsed credential fields anywhere, and inactive account snapshots stay opaque blobs in Keychain.

What this means for Pi:

- No second `/logout` and `/login` flow is needed: after a switch, a freshly started Pi session authenticates as the same account Codex is using.
- A Pi process that is already running keeps the credential it loaded at startup (Pi reads its auth file once when the process starts). Restart Pi after switching accounts.
- If a running Pi session refreshes its own token (Pi writes the refreshed credential back), it replaces the `openai-codex` entry with its session’s account. Restart Pi promptly after switching to avoid this.

Failure behavior:

- If Pi’s auth file exists but cannot be read or is not a JSON object, or the Codex snapshot cannot be converted, the switch fails as a whole and reports an error; nothing is changed (this includes Codex’s own auth file). Fix or remove the broken file, then switch again.
- Switcheroo never exposes token contents in logs, errors, or status messages.

Switcheroo does not call any Pi or OpenAI APIs and never refreshes Pi credentials itself. When Pi refreshes the synced credential during normal use, that is Pi writing to its own file; Switcheroo simply preserves whatever Pi wrote, exactly like it preserves any unrelated provider entry.

## Threat Model (Plain English)

Switcheroo is meant to reduce friction, not to provide stronger security than Keychain + your macOS login already provide.

Assumptions:

- If an attacker has local access to your user session, you’re already in trouble. They can read your active `~/.codex/auth.json`.
- Keychain protects inactive snapshots better than storing multiple `auth.json` files on disk.

Non-goals:

- No “encrypted vault” UI/UX beyond Keychain.
- No attempt to hide the active `auth.json` from your own user account (Codex needs it).
- No remote sync.

## Token Refresh

Switcheroo does not implement token refresh logic and never calls model or platform APIs.

What it does instead:

- While an account is active, Codex may update `~/.codex/auth.json` on its own (for example when it refreshes a token during normal use).
- Switcheroo snapshots the active `auth.json` back into Keychain when it starts, before switching accounts, and during its background sync window, but only when it can match the file to an existing Switcheroo account.
- The menu bar app only runs 15-second background sync polling when the active access token has less than 2 days and 5 minutes left. Outside that window it schedules a later recheck instead of continuously reading credentials.
- The menu bar also has an “Import logged-in account” action that creates a new stored account snapshot from the current auth file, or refreshes an existing matching account instead of creating a duplicate.

Practical takeaway:

- If you want an account’s stored snapshot to stay fresh, make that account active occasionally and run a normal Codex command/app workflow, then let Switcheroo capture the updated file. If the current auth file is for an account that has not been added, use the explicit import action.

## Usage Display Network Calls

The menu bar app makes one read-only network call per saved account, per explicit usage batch, to show remaining allowance:

- **Endpoint class**: the Codex usage endpoint, the same one the Codex CLI uses for its rate-limit/usage display. For ChatGPT logins this is `GET https://chatgpt.com/backend-api/wham/usage`; Codex API style hosts use `GET {base}/api/codex/usage`. FedRAMP accounts additionally send `X-OpenAI-Fedramp: true`, derived from the saved id-token claim. This is not a model, platform, or billing API.
- **When calls occur**: at app launch, each time the menu is opened (if the last result is over a minute old), and after every account switch, as one all-account batch - one request per account, each authenticated with that account's own saved credential. Failed rows respect a retry cooldown (including the server's `Retry-After` hint for 429 responses), a request is skipped while one is already in flight for the same account, and network concurrency is capped at three in-flight requests. The background auth-sync timer never triggers usage requests; never a polling service.
- **What credential is used**: each account's saved `auth.json` snapshot is read from Keychain into memory, and only that account's access token (plus its ChatGPT account id, if present) is sent as request headers (`Authorization: Bearer …`, `ChatGPT-Account-ID`). Tokens are never placed in URLs, query strings, logs, or error messages.
- **What is never persisted or logged**: usage results, fetched credentials, and request/response bodies are kept in memory only, keyed by account id, and cleared on app exit. The HTTP session is ephemeral with URL caching, cookie storage, and URL credential storage disabled, so no request or response data touches a persistent on-disk store. No usage telemetry or history is written to disk.
- **Failure behavior**: authentication, offline, rate-limiting, and malformed-response failures surface as a recoverable `Usage unavailable` state on that account's row with secret-free hints. They never modify, delete, or refresh saved credentials, never block account switching, and never affect other accounts' rows.
- **Token refresh is out of scope**: if a saved access token is rejected, that row shows an unavailable hint; Switcheroo does not attempt to refresh it. Token refresh is planned as a separate future task on the authenticated Codex API base layer.
