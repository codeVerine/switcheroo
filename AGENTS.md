# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

- Add durable project-specific notes here as they are discovered through real work.


- No linter is configured. CI (`.github/workflows/ci.yml`) runs `swift test`, a release build of the `switcheroo` product, and `./scripts/bundle_app.sh`.
- Run `swift test` locally; the full suite is fast (about 1 second).

## Pi auth-target sync sharp edges

- Switching accounts in Switcheroo also rewrites Pi's `openai-codex` credential in `~/.pi/agent/auth.json` (or `$PI_CODING_AGENT_DIR/auth.json`). See `Sources/SwitcherooPiAdapter/PiAuthTargetAdapter.swift` for the verified schema and conversion rules. The write is a Pi-compatible locked provider-scoped update (`<path>.lock` directory with mtime staleness, matching Pi's `proper-lockfile`).
- Pi credential semantics by version: Pi 0.83.x read auth.json once at process start (restart required after switching). Pi 0.84+ (`readLatestData` in `dist/core/auth-storage.js`) detects external file revisions and reloads under the lock before the next credential read; a restart is only needed for an already-open session/transport. Pi's `chatgpt_account_id` is derived from the access token, so the adapter requires that claim and rejects conflicting id-token/`tokens.account_id` values.
- The authoritative Pi source lives outside this repo: `@earendil-works/pi-coding-agent` (installed e.g. at `/opt/homebrew/lib/node_modules/@earendil-works/pi-coding-agent`); its `dist/core/auth-storage.js` and `dist/auth/oauth/openai-codex.js` (under `pi-ai`) define auth.json layout, lock, and credential semantics.

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
