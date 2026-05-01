# Architecture

Switcheroo is a single SwiftPM package with layered targets:

- `SwitcherooCore` (library)
- `SwitcherooPresentation` (library)
- `SwitcherooCodexProvider` (library, built-in provider)
- `SwitcherooMacAdapters` (library, macOS adapters)
- `SwitcherooDefaultApp` (library, composition root)
- `switcheroo` (CLI executable)
- `SwitcherooMenuBar` (menu bar executable)

The design goal is to keep the domain and presentation layers provider- and platform-agnostic, and push macOS/Codex specifics behind protocols.

## Core Flow

### Add Account (Official Login)

1. Create an account id.
2. Create a temporary `CODEX_HOME` directory under:
   - `~/Library/Application Support/Switcheroo/login/<provider>/<account-id>/`
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

- `Sources/SwitcherooCore/SwitcherooEngine.swift`
  - Provider-agnostic orchestration (config + secure store + swapping active auth file).
- `Sources/SwitcherooPresentation/SwitcherooApp.swift`
  - Shared app state/actions (framework-free).
- `Sources/SwitcherooCodexProvider/CodexProvider.swift`
  - Codex provider implementation (auth file path + login prep).
- `Sources/SwitcherooMacAdapters/MacConfigStore.swift`
  - macOS config persistence (`~/Library/Application Support/Switcheroo/config.json`).
- `Sources/SwitcherooMacAdapters/MacKeychainSecureStore.swift`
  - macOS Keychain storage for auth snapshots.
- `Sources/SwitcherooMacAdapters/CodexLoginRunner.swift`
  - macOS login interaction (in-process TTY vs Terminal).
- `Sources/SwitcherooDefaultApp/DefaultApp.swift`
  - Concrete wiring used by both shells.
