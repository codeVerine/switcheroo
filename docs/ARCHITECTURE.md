# Architecture

Switcheroo is a single SwiftPM package with layered targets:

- `SwitcherooCore` (library)
- `SwitcherooPresentation` (library)
- `SwitcherooCodexProvider` (library, built-in provider)
- `SwitcherooMacAdapters` (library, macOS adapters)
- `SwitcherooDefaultApp` (library, composition root)
- `switcheroo` (CLI executable)
- `SwitcherooMenuBar` (menu bar executable)

The menu bar app is the primary user experience. The CLI exists as an optional, thin frontend over the same shared app layer.

The design goal is to keep the domain and presentation layers provider- and platform-agnostic, and push macOS/Codex specifics behind protocols.

Guardrail: keep business logic in `SwitcherooCore` / `SwitcherooPresentation`. The CLI and menu bar app should only handle UI/UX concerns (argument parsing, rendering, menus) and call into the shared app layer.

## Core Flow

### Add Account (Official Login)

1. Create an account id.
2. Create a temporary `CODEX_HOME` directory under:
   - `~/Library/Application Support/Switcheroo/login/<provider>/<account-id>/`
3. Run `codex login` with that `CODEX_HOME` so Codex writes a fresh `auth.json`.
4. Import that `auth.json` snapshot through the shared auth-snapshot upsert path.
5. If the auth identity matches an existing account, refresh that account instead of appending a duplicate.
6. Delete the temporary `CODEX_HOME` directory.

Menu bar app runs the login in Terminal via AppleScript (`osascript`). CLI runs it in-process and attaches to the user’s TTY.

### Switch

1. Load the Keychain blob for the account id.
2. Atomically overwrite the active Codex auth file (default `~/.codex/auth.json`).
3. Mark that account as active in config.
4. Refresh the menu state with an account-switch usage trigger: one fresh all-account generation replaces any cached rows so the dropdown never shows another account's numbers.

### Usage Display

1. On refresh, Switcheroo plans a usage batch over every saved account. Menu-open refreshes skip rows with fresh results (under a minute old), rows already in flight for the current generation, and failed rows inside their retry cooldown (the server's `Retry-After` hint extends the cooldown for 429 responses). Account switches always start one full all-account generation; adding, importing, or deleting accounts always advances the generation so superseded or deleted results can never land. Rows needing a fetch are marked `.loading` synchronously and removed accounts are pruned.
2. Each account's saved `auth.json` snapshot is read from Keychain serially (in memory only) into an immutable batch context that captures the provider id, so the network phase never enters the secure store and a concurrent provider change cannot change credential lookup. Each account's credential authenticates one GET to the usage endpoint (`/wham/usage` on `chatgpt.com/backend-api`, or `/api/codex/usage` for Codex API style hosts) with `Authorization: Bearer <access token>`, `ChatGPT-Account-ID`, and `X-OpenAI-Fedramp: true` when the saved id-token claims mark the account FedRAMP. Every account uses its own credential; results stay keyed by account id.
3. The network phase runs with a small rolling concurrency limit (three in-flight requests); the next child starts only when one completes.
4. The response reports consumption (`used_percent`) per window; the usage client derives remaining allowance as `clamp(100 − used, 0, 100)` and classifies windows by their reported duration (5h ≈ 18000s, weekly ≈ 604800s), falling back to primary/secondary position. A 200 response with no usable window is treated as malformed so the row shows unavailable instead of silently hiding.
5. Failures are isolated per account (auth, offline, rate limiting, malformed responses) and become that row's recoverable `Usage unavailable` state with a secret-free reason; other rows keep their own results.
6. Results publish only when they belong to the current generation AND the account is still live, so older batches and deleted accounts never land; still-loading superseded accounts fold into the replacement generation so no row gets stuck on `Checking usage…`.
7. When results land, the app fires `onUsageUpdated` so the menu bar re-reads the snapshot and the open dropdown updates live. The auth-sync timer path refreshes account metadata only and can never trigger usage requests. The transport (an ephemeral, no-cache/no-cookie/no-credential-store `URLSession`), endpoint URL, and clock stay injectable (`CodexHTTPTransport`, `CodexAPIClient`, and the usage fetcher's `now` closure) for deterministic tests without live requests.

### Sync

1. Read the active `auth.json` from disk.
2. Resolve its best-effort identity from `tokens.account_id`, falling back to email when needed.
3. Store it back into Keychain only when it matches an existing Switcheroo account.
4. If it matches a different existing account than the configured active account, correct the active account id.

The shared app layer runs the same sync path for CLI and menu bar actions. The CLI attempts it once per command. The menu bar app attempts it on launch, before switching accounts, and on a timer only when the active access token is within 2 days and 5 minutes of expiry; otherwise it schedules a later recheck.

The visible menu bar action for creating a new account from the current logged-in session is “Import logged-in account”.

## Key Types / Files

- `Sources/SwitcherooCore/SwitcherooEngine.swift`
  - Provider-agnostic orchestration (config + secure store + swapping active auth file).
- `Sources/SwitcherooCore/UsageModels.swift`
  - Provider-agnostic usage models and the `AccountUsageFetching` protocol.
- `Sources/SwitcherooPresentation/SwitcherooApp.swift`
  - Shared app state/actions (framework-free), including usage fetch orchestration with latest-request-wins semantics.
- `Sources/SwitcherooCodexProvider/CodexProvider.swift`
  - Codex provider implementation (auth file path + login prep).
- `Sources/SwitcherooCodexProvider/CodexAPIClient.swift`
  - Reusable authenticated base layer for Codex backend APIs: request/header construction, transport protocol, credential parsing. No token refresh (planned for a later task).
- `Sources/SwitcherooCodexProvider/CodexUsageFetcher.swift`
  - Codex usage endpoint client: response decoding, remaining-allowance derivation, window classification.
- `Sources/SwitcherooMacAdapters/MacConfigStore.swift`
  - macOS config persistence (`~/Library/Application Support/Switcheroo/config.json`).
- `Sources/SwitcherooMacAdapters/MacKeychainSecureStore.swift`
  - macOS Keychain storage for auth snapshots.
- `Sources/SwitcherooMacAdapters/CodexLoginRunner.swift`
  - macOS login interaction (in-process TTY vs Terminal).
- `Sources/SwitcherooDefaultApp/DefaultApp.swift`
  - Concrete wiring used by both shells.
