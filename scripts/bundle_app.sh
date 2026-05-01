#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

mkdir -p /private/tmp/switcheroo-swiftpm-cache /private/tmp/switcheroo-swiftpm-config /private/tmp/switcheroo-swiftpm-security /private/tmp/switcheroo-clang-module-cache
export CLANG_MODULE_CACHE_PATH="/private/tmp/switcheroo-clang-module-cache"
swift build --disable-sandbox -c release --product SwitcherooMenuBar \
  --cache-path /private/tmp/switcheroo-swiftpm-cache \
  --config-path /private/tmp/switcheroo-swiftpm-config \
  --security-path /private/tmp/switcheroo-swiftpm-security \
  --manifest-cache local

BIN="$ROOT_DIR/.build/release/SwitcherooMenuBar"
APP_DIR="$ROOT_DIR/dist/Switcheroo.app"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BIN" "$APP_DIR/Contents/MacOS/Switcheroo"
chmod +x "$APP_DIR/Contents/MacOS/Switcheroo"

cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleName</key>
  <string>Switcheroo</string>
  <key>CFBundleDisplayName</key>
  <string>Switcheroo</string>
  <key>CFBundleIdentifier</key>
  <string>com.switcheroo.menubar</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleExecutable</key>
  <string>Switcheroo</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleSupportedPlatforms</key>
  <array>
    <string>MacOSX</string>
  </array>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>Switcheroo opens Terminal to run the official Codex login flow for each account.</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"

codesign --force --deep --sign - "$APP_DIR"

echo "Built: $APP_DIR"
