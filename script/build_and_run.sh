#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Darkbloom"
PROCESS_NAME="DarkbloomApp"
BUNDLE_ID="dev.darkbloom.app"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_DIR="$ROOT_DIR/provider-swift"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$PROCESS_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"

pkill -x "$PROCESS_NAME" >/dev/null 2>&1 || true

swift build --package-path "$PACKAGE_DIR" --product "$PROCESS_NAME"
BUILD_DIR="$(swift build --package-path "$PACKAGE_DIR" --show-bin-path)"
BUILD_BINARY="$BUILD_DIR/$PROCESS_NAME"
RESOURCE_BUNDLE="$BUILD_DIR/DarkbloomProvider_DarkbloomApp.bundle"
SHADER_SOURCE="$PACKAGE_DIR/Sources/DarkbloomApp/Resources/DarkbloomSpatialField.metal"
SHADER_AIR="$RESOURCE_BUNDLE/DarkbloomSpatialField.air"

xcrun -sdk macosx metal -c "$SHADER_SOURCE" -o "$SHADER_AIR"
xcrun -sdk macosx metallib "$SHADER_AIR" -o "$RESOURCE_BUNDLE/default.metallib"
rm -f "$SHADER_AIR"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
cp "$PACKAGE_DIR/Resources/DarkbloomApp/Chivo-Regular.ttf" "$APP_RESOURCES/Chivo-Regular.ttf"
cp "$PACKAGE_DIR/Resources/DarkbloomApp/Chivo-Medium.ttf" "$APP_RESOURCES/Chivo-Medium.ttf"
cp "$PACKAGE_DIR/Resources/DarkbloomApp/Info.plist" "$INFO_PLIST"
cp -R "$RESOURCE_BUNDLE" "$APP_RESOURCES/"
chmod +x "$APP_BINARY"

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$PROCESS_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    APP_PID="$(pgrep -x "$PROCESS_NAME" | head -1)"
    test -n "$APP_PID"
    swift -e '
      import CoreGraphics
      import Foundation

      let pid = Int32(CommandLine.arguments[1])!
      let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID)
          as? [[String: Any]] ?? []
      let hasMainWindow = windows.contains { window in
          guard (window[kCGWindowOwnerPID as String] as? Int32) == pid,
                let bounds = window[kCGWindowBounds as String],
                let frame = CGRect(dictionaryRepresentation: bounds as! CFDictionary)
          else { return false }
          return frame.width >= 900 && frame.height >= 620
      }
      exit(hasMainWindow ? 0 : 1)
    ' "$APP_PID"
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
