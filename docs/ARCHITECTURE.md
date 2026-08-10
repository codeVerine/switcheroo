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

One serialized, crash-safe transaction:

1. Acquire the cross-process switch lock (`~/Library/Application Support/Switcheroo/state/switch.lock`, flock) and reconcile any journal left by an interrupted transaction.
2. Convert and validate the snapshot for every configured auth target (Codex, Pi, ...) and reject colliding destinations. This is read-only; failures abort before anything is modified.
3. Durably journal the transaction (destination pre-images, Keychain pre-images, pre-switch config) to `~/Library/Application Support/Switcheroo/state/transaction.json` with user-only permissions.
4. Apply Keychain changes (activations), publish every destination through its adapter, persist the mutated config, mark the journal committed, then delete it.

The same orchestration runs when an "add account" or "import" flow activates an account (set-active); importing the already-active account skips the redundant Codex rewrite but still synchronizes Pi.

### Auth Target Synchronization

Switching an account keeps the active Codex credential and every configured harness auth target in sync, so the same account is selected everywhere without a second login flow. The orchestration lives in `SwitcherooEngine` and is target-agnostic: it invokes every registered adapter through the same prepare/publish/rollback transaction, and each adapter owns its destination-specific write semantics.

`AuthTargetAdapter` (in `Sources/SwitcherooCore/AuthTargetAdapter.swift`) defines the responsibilities of an authentication target:

- target identity: `id`, `displayName`
- destination resolution: `destinationAuthFilePath(forProviderState:)`
- supported source validation/conversion: `convertedCredential(fromSourceAuthData:)`
- destination validation before any publication: `validateExistingDestination(existingDestinationData:destinationPath:)`
- destination-specific preservation or replacement at publication: `writeDestination(credential:sourceAuthData:destinationPath:fileIO:)`
- atomic secure writes and transaction serialization are the engine's job: every destination is written via a unique same-directory temporary file created exclusively with mode `0o600` (fsynced before an atomic rename), and error text is constructed from fixed strings and paths only (secret-free)

Built-in adapters:

- `CodexAuthTargetAdapter` (`Sources/SwitcherooCodexProvider/CodexAuthTargetAdapter.swift`): whole-file replacement. The destination becomes exactly the selected opaque Keychain snapshot (skipped when the file already holds those bytes); the only validation is that the snapshot is non-empty.
- `PiAuthTargetAdapter` (`Sources/SwitcherooPiAdapter/PiAuthTargetAdapter.swift`): locked section upsert. It converts the snapshot into Pi's `openai-codex` OAuth credential in-memory (never persisting parsed fields; account id from the access token, matching Pi) and publishes with a Pi-compatible lock (`<path>.lock` directory with mtime-based staleness, as Pi's `proper-lockfile`): acquire, re-read, validate, merge only `openai-codex` while preserving every other provider entry, write, release - in `~/.pi/agent/auth.json` (or `$PI_CODING_AGENT_DIR/auth.json`).

Orchestration and failure semantics:

1. Prepare first (under the transaction lock): canonicalize every resolved destination (tilde expansion plus symlink resolution) and reject duplicates before reading or writing anything; validate/convert the source snapshot and validate existing destination documents. Deterministic failures abort the transaction with nothing changed.
2. Journal durably, then publish every destination atomically with `0o600` permissions (created directories get `0o700`), persist config, mark the journal committed, and clear it.
3. On a failure, every published mutation (destinations, Keychain, config) is rolled back in reverse order; rollbacks are compare-and-swap guarded, and every failed recovery step is reported in a `rollbackIncomplete` error.
4. If a rollback cannot complete - or the process is killed mid-transaction - the journal survives and the next launch reconciles it: an uncommitted transaction is rolled back, a committed one is completed. An unreadable journal blocks startup with the journal path in the error.

The switch is designed to behave all-or-nothing, including across crashes. If a concurrent modification prevents rollback from completing, Switcheroo reports the affected paths and leaves the journal for recovery instead of guessing.

Adding another built-in auth target:

1. Implement `AuthTargetAdapter` in a new target (mirror `Sources/SwitcherooPiAdapter/PiAuthTargetAdapter.swift`): decide how the destination path resolves, convert the Codex snapshot to the target credential (derive identity/expiry via `CodexAuthParsing.summarize`), and pick the write semantics - whole-file replacement or a keyed section upsert via the shared `AuthTargetDocument.merging` helper (locking as Pi does when the target's own process writes the file concurrently).
2. Wire it in the composition root (`Sources/SwitcherooDefaultApp/DefaultApp.swift`) by passing the adapter to `SwitcherooEngine` via `authTargetAdapters` (a non-empty target set is required; the engine refuses to start without one so switching can never silently skip the Codex file).
3. Add tests: a contract test using the fake adapter plus a conversion test for the new target.

No background service, plugin loader, or dynamic discovery is involved: adapters are built-in and registered at composition time.

### Usage Display

1. Usage refresh is tiered. App launch seeds every saved account once; while the app runs, the active account refreshes when its result is older than 5 minutes and inactive accounts when older than 30 minutes; opening the menu renders the cached rows and never fetches. Account switches always start one full all-account generation (bypassing the freshness cache); adding, importing, or deleting accounts always advances the generation so superseded or deleted results can never land. A tiered refresh skips rows with fresh results (per their tier), rows already in flight for the current generation, and failed rows inside their retry cooldown (the server's `Retry-After` hint extends the cooldown for 429 responses). Rows needing a fetch are marked `.loading` synchronously and removed accounts are pruned.
2. Each account's saved `auth.json` snapshot is read from Keychain serially (in memory only) into an immutable batch context that captures the provider id, so the network phase never enters the secure store and a concurrent provider change cannot change credential lookup. Each account's credential authenticates one GET to the usage endpoint (`/wham/usage` on `chatgpt.com/backend-api`, or `/api/codex/usage` for Codex API style hosts) with `Authorization: Bearer <access token>`, `ChatGPT-Account-ID`, and `X-OpenAI-Fedramp: true` when the saved id-token claims mark the account FedRAMP. Every account uses its own credential; results stay keyed by account id.
3. The network phase runs with a small rolling concurrency limit; the next child starts only when one completes. The exact per-batch limit is documented in [Data & Security](/docs/DATA-AND-SECURITY.md).
4. The response reports consumption (`used_percent`) per window; the usage client derives remaining allowance as `clamp(100 − used, 0, 100)` and classifies windows by their reported duration (5h ≈ 18000s, weekly ≈ 604800s). If a duration is unknown, fallback is position-specific: only primary is considered for five-hour and only secondary for weekly; a source consumed by an exact match is not reused. A 200 response with no usable window is treated as malformed so the row shows unavailable instead of silently hiding.
5. Failures are isolated per account (auth, offline, rate limiting, malformed responses) and become that row's recoverable `Usage unavailable` state with a secret-free reason; other rows keep their own results.
6. Results publish only when they belong to the current generation AND the account is still live, so older batches and deleted accounts never land; still-loading superseded accounts fold into the replacement generation so no row gets stuck on `Checking usage…`.
7. When results land, the app fires `onUsageUpdated` so the menu bar re-reads the snapshot and the open dropdown updates live. The auth-sync timer path refreshes account metadata only and can never trigger usage requests; the tiered usage schedule (5-minute active / 30-minute inactive) runs on its own timer. The transport (an ephemeral, no-cache/no-cookie/no-credential-store `URLSession`), endpoint URL, and clock stay injectable (`CodexHTTPTransport`, `CodexAPIClient`, and the usage fetcher's `now` closure) for deterministic tests without live requests.
### Sync

1. Read the active `auth.json` from disk.
2. Resolve its best-effort identity from `tokens.account_id`, falling back to email when needed.
3. Store it back into Keychain only when it matches an existing Switcheroo account.
4. If it matches a different existing account than the configured active account, correct the active account id.

The shared app layer runs the same sync path for CLI and menu bar actions. The CLI attempts it once per command. The menu bar app attempts it on launch, before switching accounts, and on a timer only when the active access token is within 2 days and 5 minutes of expiry; otherwise it schedules a later recheck.

The visible menu bar action for creating a new account from the current logged-in session is “Import logged-in account”.

## Key Types / Files

- `Sources/SwitcherooCore/SwitcherooEngine.swift`
  - Provider-agnostic orchestration (config + secure store + serialized crash-safe account-switch transactions + auth-target synchronization).
- `Sources/SwitcherooCore/UsageModels.swift`
  - Provider-agnostic usage models and the `AccountUsageFetching` protocol.
- `Sources/SwitcherooCore/AuthTargetAdapter.swift`
  - Auth-target adapter contract, credential/value types (exact integer preservation), and shared document merge.
- `Sources/SwitcherooCore/TransactionJournal.swift`
  - Durable crash-recovery record for in-flight switches (pre-images, pre-switch config, Keychain changes).
- `Sources/SwitcherooCore/FoundationFileIO.swift`
  - Atomic writes via unique exclusive 0600 temp files, 0700 directory creation, flock, path canonicalization.
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
