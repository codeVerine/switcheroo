# Architecture

Switcheroo is a single SwiftPM package with three targets:

- `SwitcherooCore` (library)
- `switcheroo` (CLI)
- `SwitcherooMenuBar` (menu bar app)

The core library owns all stateful behavior: config I/O, Keychain I/O, swapping `auth.json`, and login orchestration.

## Core Flow

### Add Account (Official Login)

1. Create an account id.
2. Create a temporary `CODEX_HOME` directory under:
   - `~/Library/Application Support/Switcheroo/login/<account-id>/`
3. Run `codex login` with that `CODEX_HOME` so Codex writes a fresh `auth.json`.
4. Import that `auth.json` snapshot into Keychain under the account id.
5. Delete the temporary `CODEX_HOME` directory.

Menu bar app runs the login in Terminal via AppleScript (`osascript`). CLI runs it in-process and attaches to the user’s TTY.

### Switch

1. Load the Keychain blob for the account id.
2. Atomically overwrite the active Codex auth file (default `~/.codex/auth.json`).
3. Mark that account as active in config.

### Sync

1. Read the active `auth.json` from disk.
2. Store it back into Keychain for the active account id.

The menu bar app runs `sync` on a timer (best-effort) and exposes a “Sync Now” button.

## Key Types / Files

- [Sources/SwitcherooCore/SwitcherooService.swift](../Sources/SwitcherooCore/SwitcherooService.swift)
  - The central coordinator.
- [Sources/SwitcherooCore/ConfigStore.swift](../Sources/SwitcherooCore/ConfigStore.swift)
  - Reads/writes `config.json`.
- [Sources/SwitcherooCore/KeychainStore.swift](../Sources/SwitcherooCore/KeychainStore.swift)
  - Keychain read/write for auth snapshots.
- [Sources/SwitcherooCore/CodexAuthFile.swift](../Sources/SwitcherooCore/CodexAuthFile.swift)
  - Atomic read/write for the active auth file.
- [Sources/SwitcherooMenuBar/main.swift](../Sources/SwitcherooMenuBar/main.swift)
  - Status bar item + popover UI.

