# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

- Add durable project-specific notes here as they are discovered through real work.

- No linter is configured. CI (`.github/workflows/ci.yml`) runs `swift test`, a release build of the `switcheroo` product, and `./scripts/bundle_app.sh`.
- Run `swift test` locally; the full suite is fast (about 1 second).

## Pi auth-target sync sharp edges

- Switching accounts also updates Pi's `openai-codex` credential. See `docs/DATA-AND-SECURITY.md` for the sync and storage contract, `docs/TROUBLESHOOTING.md` for reload guidance, and `Sources/SwitcherooPiAdapter/PiAuthTargetAdapter.swift` for the implementation.
- Pi's auth schema and lock protocol are external compatibility contracts. The adapter comments and tests record the currently verified behavior; re-check Pi's installed implementation before changing either.

## Transaction journal sharp edges

- Account switches journal to `~/Library/Application Support/Switcheroo/state/transaction.json` (0600) before any publication and clear it after commit; startup reconciliation rolls back or completes an interrupted transaction. A leftover journal after a failed switch is intentional (recovery record), and an unreadable journal blocks engine startup until removed. The cross-process `switch.lock` (flock) serializes every switch, including CLI vs menu-bar.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.

## Codex backend API facts
- Usage endpoint: `GET {base}/wham/usage` (ChatGPT style, base `https://chatgpt.com/backend-api`) or `{base}/api/codex/usage` (Codex API style). Auth: `Authorization: Bearer <access_token>` + `ChatGPT-Account-ID: <tokens.account_id>` when present. Response reports `used_percent` per window (`rate_limit.primary_window` 5h / `secondary_window` 1w) with `limit_window_seconds` and `reset_at`; remaining allowance is derived as `clamp(100 - used, 0, 100)`.
- Authoritative source: openai/codex repo (`codex-rs/backend-client/src/client/rate_limit_resets.rs`, `codex-rs/codex-api/src/rate_limits.rs`, `codex-rs/model-provider/src/auth.rs`, `codex-rs/tui/src/chatwidget/rate_limits.rs`). Switcheroo's implementation: `Sources/SwitcherooCodexProvider/CodexAPIClient.swift` + `CodexUsageFetcher.swift`.
