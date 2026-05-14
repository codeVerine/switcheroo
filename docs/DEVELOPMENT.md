# Development

## Build

This is a SwiftPM package with layered targets:

- `SwitcherooCore`
- `SwitcherooPresentation`
- `SwitcherooCodexProvider`
- `SwitcherooMacAdapters`
- `SwitcherooDefaultApp`
- `switcheroo`
- `SwitcherooMenuBar`

Menu bar app (dev run):

```bash
swift run SwitcherooMenuBar
```

CLI (optional; mostly for development):

```bash
swift build -c debug --product switcheroo
./.build/debug/switcheroo list
```

If you need to inspect the modular targets directly, `swift package describe` will show the package graph.

## Bundle A `.app`

```bash
./scripts/bundle_app.sh
open dist/Switcheroo.app
```

The bundling script:

- builds `SwitcherooMenuBar` in release mode
- creates a minimal `.app` bundle structure
- ad-hoc signs the bundle (`codesign --sign -`)

For a real distribution, you will likely want to:

- use a stable bundle identifier you control
- sign with a Developer ID certificate
- notarize the app

## Logging

Switcheroo uses Apple Unified Logging (`OSLog`) with subsystem `com.switcheroo`.

```bash
log stream --predicate 'subsystem == "com.switcheroo"' --style compact
```
