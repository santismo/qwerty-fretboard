#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Qwerty Fretboard"
PRODUCT_NAME="QwertyFretboard"
BUNDLE_ID="com.santismo.qwerty-fretboard"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"

cd "$ROOT_DIR"
pkill -x "$APP_NAME" >/dev/null 2>&1 || true

swift build
BUILD_BINARY="$(swift build --show-bin-path)/$PRODUCT_NAME"

if [[ ! -f "$ROOT_DIR/Resources/AppIcon.icns" ]]; then
  swift "$ROOT_DIR/script/generate_icon.swift"
fi

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_RESOURCES/AppIcon.icns"

cat >"$APP_CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>Qwerty Fretboard uses keyboard monitoring only while MIDI mode is active.</string>
  <key>NSInputMonitoringUsageDescription</key>
  <string>Qwerty Fretboard needs input monitoring to convert keyboard playing into MIDI while MIDI mode is active.</string>
</dict>
</plist>
PLIST

if /usr/bin/codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null 2>&1; then
  :
else
  echo "codesign failed" >&2
  exit 1
fi

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -f "$APP_BUNDLE/Contents/MacOS/$APP_NAME" >/dev/null
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  *)
    echo "usage: $0 [run|--verify|--logs]" >&2
    exit 2
    ;;
esac
