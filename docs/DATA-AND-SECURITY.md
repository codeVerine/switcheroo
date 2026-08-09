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

The menu bar app makes one read-only network call to show remaining allowance:

- **Endpoint class**: the Codex usage endpoint, the same one the Codex CLI uses for its rate-limit/usage display. For ChatGPT logins this is `GET https://chatgpt.com/backend-api/wham/usage`; Codex API style hosts use `GET {base}/api/codex/usage`. This is not a model, platform, or billing API.
- **When calls occur**: at app launch, each time the menu is opened (if the last result is over a minute old), and right after an account switch. One request at a time for the active account; never a polling service.
- **What credential is used**: the active account's saved `auth.json` snapshot is read from Keychain into memory, and only the access token (plus the ChatGPT account id, if present) is sent as request headers (`Authorization: Bearer …`, `ChatGPT-Account-ID`). The token is never placed in URLs, query strings, logs, or error messages.
- **What is never persisted or logged**: usage results, fetched credentials, and request/response bodies are kept in memory only, keyed by account id, and cleared on app exit. No usage telemetry or history is written to disk.
- **Failure behavior**: authentication, offline, rate-limiting, and malformed-response failures surface as a recoverable `Usage unavailable` display state with secret-free hints. They never modify, delete, or refresh saved credentials, and never block account switching.
- **Token refresh is out of scope**: if the saved access token is rejected, the row shows an unavailable hint; Switcheroo does not attempt to refresh it. Token refresh is planned as a separate future task on the authenticated Codex API base layer.
