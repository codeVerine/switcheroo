# Architecture

Switcheroo is a single SwiftPM package with layered targets:

- `SwitcherooCore` (library)
- `SwitcherooPresentation` (library)
- `SwitcherooCodexProvider` (library, built-in provider)
- `SwitcherooPiAdapter` (library, built-in auth target)
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
2. Convert and merge that snapshot for every configured auth target (Codex, Pi, ...). This is read-only; conversion or merge failures abort before anything is modified.
3. Atomically write each target's auth file with user-only permissions (`0o600`), in registration order.
4. Mark that account as active in config and persist.

The same orchestration runs when an "add account" or "import" flow activates an account (set-active), because those paths also rewrite the active Codex auth file.

### Auth Target Synchronization

Switching an account keeps the active Codex credential and every configured harness auth target in sync, so the same account is selected everywhere without a second login flow. The orchestration lives in `SwitcherooEngine` and is target-agnostic: it invokes every registered adapter through the same prepare/write/rollback process, and each adapter owns its destination-specific write semantics.

`AuthTargetAdapter` (in `Sources/SwitcherooCore/AuthTargetAdapter.swift`) defines the responsibilities of an authentication target:

- target identity: `id`, `displayName`
- destination resolution: `destinationAuthFilePath(forProviderState:)`
- supported source validation/conversion and destination-specific preservation or replacement: `destinationDocument(fromSourceAuthData:existingDestinationData:)`
- atomic secure writes are the engine's job: every destination is written via temp-file replace with `0o600` permissions, and error text is constructed from fixed strings and paths only (secret-free)

Built-in adapters:

- `CodexAuthTargetAdapter` (`Sources/SwitcherooCodexProvider/CodexAuthTargetAdapter.swift`): whole-file replacement. The destination becomes exactly the selected opaque Keychain snapshot; the only validation is that the snapshot is non-empty.
- `PiAuthTargetAdapter` (`Sources/SwitcherooPiAdapter/PiAuthTargetAdapter.swift`): section upsert. It converts the snapshot into Pi's `openai-codex` OAuth credential in-memory (never persisting parsed fields) and replaces only that top-level key, preserving every other provider entry, in `~/.pi/agent/auth.json` (or `$PI_CODING_AGENT_DIR/auth.json`).

Orchestration and failure semantics:

1. Prepare first: validate/convert/merge for every adapter before any file is written. A malformed, incomplete, or unsupported source credential, or a malformed destination file, fails the whole operation with nothing changed.
2. Write every destination atomically (temp file + replace) with `0o600` permissions. Destination files and parent directories are created when absent.
3. On a write failure, previously written destinations are rolled back to their previous bytes. Rollbacks are compare-and-swap guarded: a file is only restored if it still contains exactly what Switcheroo wrote, so a concurrent writer is never clobbered.
4. If config persistence fails after the writes, the same compare-and-swap rollback reverts the destinations.
5. If a rollback cannot complete (for example, another process modified a file mid-switch), Switcheroo surfaces a `rollbackIncomplete` error naming the affected files instead of claiming success. Recovery is to repair or remove the affected auth file and switch again.

The switch therefore behaves all-or-nothing: either every destination file holds the new account, or none of them do (and the error says so).

Adding another built-in auth target:

1. Implement `AuthTargetAdapter` in a new target (mirror `Sources/SwitcherooPiAdapter/PiAuthTargetAdapter.swift`): decide how the destination path resolves, convert the Codex snapshot to the target credential (derive identity/expiry via `CodexAuthParsing.summarize`), and pick the write semantics - whole-file replacement or a keyed section upsert via the shared `AuthTargetDocument.merging` helper.
2. Wire it in the composition root (`Sources/SwitcherooDefaultApp/DefaultApp.swift`) by passing the adapter to `SwitcherooEngine` via `authTargetAdapters`.
3. Add tests: a contract test using the fake adapter plus a conversion test for the new target.

No background service, plugin loader, or dynamic discovery is involved: adapters are built-in and registered at composition time.

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
=======
2. Convert and merge that snapshot for every configured auth target (Pi, ...). This is read-only; conversion or merge failures abort before anything is modified.
3. Atomically overwrite the active Codex auth file (default `~/.codex/auth.json`).
4. Mark that account as active in config.
5. Atomically write each target's auth file with user-only permissions (`0o600`).

The same orchestration runs when an "add account" or "import" flow activates an account (set-active), because those paths also rewrite the active Codex auth file.

### Auth Target Synchronization

Switching an account keeps the active Codex credential and every configured harness auth target in sync, so the same account is selected everywhere without a second login flow. The orchestration lives in `SwitcherooEngine` and is target-agnostic: it knows only the `AuthTargetAdapter` contract.

`AuthTargetAdapter` (in `Sources/SwitcherooCore/AuthTargetAdapter.swift`) defines the responsibilities of an authentication target:

- target identity: `id`, `displayName`
- destination resolution: `destinationAuthFilePath`
- supported source validation/conversion: `convertedCredential(fromSourceAuthData:)`
- preservation of unrelated destination credentials: `destinationDocument(byMerging:existingDestinationData:)` (default implementation keeps every top-level entry and replaces only the credential key)

`PiAuthTargetAdapter` is the first built-in target. It converts the active Codex snapshot into Pi's `openai-codex` OAuth credential in-memory (never persisting parsed fields) and merges it into `~/.pi/agent/auth.json` (or `$PI_CODING_AGENT_DIR/auth.json`).

Orchestration and failure semantics:

1. Prepare first: convert and merge for every adapter before any file is written. A malformed, incomplete, or unsupported source credential, or a malformed destination file, fails the whole operation with nothing changed.
2. Write the active Codex auth file and persist config, then write target files atomically (temp file + replace) with `0o600` permissions. The destination file and its parent directory are created when absent.
3. On a target write failure, previously written targets and the active Codex auth file are rolled back to their previous bytes. Rollbacks are compare-and-swap guarded: a file is only restored if it still contains exactly what Switcheroo wrote, so a concurrent writer is never clobbered.
4. If a rollback cannot complete (for example, another process modified a file mid-switch), Switcheroo surfaces a `rollbackIncomplete` error naming the affected files instead of claiming success. Recovery is to repair or remove the affected auth file and switch again.

The switch therefore behaves all-or-nothing: either both the Codex file and all target files hold the new account, or none of them do (and the error says so).

Adding another built-in auth target:

1. Implement `AuthTargetAdapter` in a new target (mirror `Sources/SwitcherooPiAdapter/PiAuthTargetAdapter.swift`): decide the destination path, convert the Codex snapshot to the target credential (derive identity/expiry via `CodexAuthParsing.summarize`), and use the default document merge or override it.
2. Wire it in the composition root (`Sources/SwitcherooDefaultApp/DefaultApp.swift`) by passing the adapter to `SwitcherooEngine` via `authTargetAdapters`.
3. Add tests: a contract test using the fake adapter plus a conversion test for the new target.

No background service, plugin loader, or dynamic discovery is involved: adapters are built-in and registered at composition time.

### Sync

1. Read the active `auth.json` from disk.
2. Resolve its best-effort identity from `tokens.account_id`, falling back to email when needed.
3. Store it back into Keychain only when it matches an existing Switcheroo account.
4. If it matches a different existing account than the configured active account, correct the active account id.

The shared app layer runs the same sync path for CLI and menu bar actions. The CLI attempts it once per command. The menu bar app attempts it on launch, before switching accounts, and on a timer only when the active access token is within 2 days and 5 minutes of expiry; otherwise it schedules a later recheck.

The visible menu bar action for creating a new account from the current logged-in session is “Import logged-in account”.

## Key Types / Files

- `Sources/SwitcherooCore/SwitcherooEngine.swift`
  - Provider-agnostic orchestration (config + secure store + swapping active auth file + auth-target synchronization).
- `Sources/SwitcherooCore/UsageModels.swift`
  - Provider-agnostic usage models and the `AccountUsageFetching` protocol.
- `Sources/SwitcherooCore/AuthTargetAdapter.swift`
  - Auth-target adapter contract, credential/value types, and shared document merge.
- `Sources/SwitcherooCore/CodexAuthParsing.swift`
  - Best-effort, in-memory parsing of Codex auth data for metadata and auth-target conversion (identity, expiry).
- `Sources/SwitcherooPresentation/SwitcherooApp.swift`
  - Shared app state/actions (framework-free), including usage fetch orchestration with latest-request-wins semantics.
- `Sources/SwitcherooCodexProvider/CodexProvider.swift`
  - Codex provider implementation (auth file path + login prep).
- `Sources/SwitcherooCodexProvider/CodexAPIClient.swift`
  - Reusable authenticated base layer for Codex backend APIs: request/header construction, transport protocol, credential parsing. No token refresh (planned for a later task).
- `Sources/SwitcherooCodexProvider/CodexUsageFetcher.swift`
  - Codex usage endpoint client: response decoding, remaining-allowance derivation, window classification.
- `Sources/SwitcherooCodexProvider/CodexAuthTargetAdapter.swift`
  - Codex auth target: whole-file replacement of the active Codex auth.json with the opaque snapshot.
- `Sources/SwitcherooPiAdapter/PiAuthTargetAdapter.swift`
  - Pi auth target: converts the active Codex credential to Pi's `openai-codex` OAuth credential and upserts only that section.
- `Sources/SwitcherooMacAdapters/MacConfigStore.swift`
  - macOS config persistence (`~/Library/Application Support/Switcheroo/config.json`).
- `Sources/SwitcherooMacAdapters/MacKeychainSecureStore.swift`
  - macOS Keychain storage for auth snapshots.
- `Sources/SwitcherooMacAdapters/CodexLoginRunner.swift`
  - macOS login interaction (in-process TTY vs Terminal).
- `Sources/SwitcherooDefaultApp/DefaultApp.swift`
  - Concrete wiring used by both shells.
