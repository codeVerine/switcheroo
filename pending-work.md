# Pending Work

- Onboarding safety: when the user has an existing `~/.codex/auth.json` (Account A) and adds their first Switcheroo account via “Add account” but logs into a different account (Account B), we can overwrite `~/.codex/auth.json` without ever snapshotting Account A. Add a guardrail so the first-time flow preserves the pre-existing active auth (ex: auto-import the currently logged-in account first, or prompt the user to run “Import logged-in account” before switching the active auth).
- Windows goal: keep `SwitcherooCore`/`SwitcherooPresentation` in Swift and implement a Windows 10+ native tray UI that talks to a Swift helper-process (JSON/IPC) rather than a Swift DLL.
