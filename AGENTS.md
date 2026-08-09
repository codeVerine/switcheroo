# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

- Add durable project-specific notes here as they are discovered through real work.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.

## Codex backend API facts

- Usage endpoint: `GET {base}/wham/usage` (ChatGPT style, base `https://chatgpt.com/backend-api`) or `{base}/api/codex/usage` (Codex API style). Auth: `Authorization: Bearer <access_token>` + `ChatGPT-Account-ID: <tokens.account_id>` when present. Response reports `used_percent` per window (`rate_limit.primary_window` 5h / `secondary_window` 1w) with `limit_window_seconds` and `reset_at`; remaining allowance is derived as `clamp(100 - used, 0, 100)`.
- Authoritative source: openai/codex repo (`codex-rs/backend-client/src/client/rate_limit_resets.rs`, `codex-rs/codex-api/src/rate_limits.rs`, `codex-rs/model-provider/src/auth.rs`, `codex-rs/tui/src/chatwidget/rate_limits.rs`). Switcheroo's implementation: `Sources/SwitcherooCodexProvider/CodexAPIClient.swift` + `CodexUsageFetcher.swift`.
