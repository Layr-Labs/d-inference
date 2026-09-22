#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="DarkbloomConnect"
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
MODE="${1:-run}"
case "$MODE" in run|--verify|--build) ;; *) echo "usage: $0 [run|--verify|--build]" >&2; exit 2 ;; esac
# Stop only this checkout's companion before replacing its mapped executable.
# The provider and companions launched from other worktrees are untouched.
while IFS= read -r pid; do
    command_line="$(ps -p "$pid" -o command= || true)"
    if [[ "$command_line" == "$APP_BUNDLE/Contents/MacOS/$APP_NAME" ]]; then kill "$pid" || true; fi
done < <(pgrep -x "$APP_NAME" || true)
swift build --package-path "$ROOT_DIR"
BIN_PATH="$(swift build --package-path "$ROOT_DIR" --show-bin-path)"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
cp "$BIN_PATH/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cat > "$APP_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>DarkbloomConnect</string>
<key>CFBundleIdentifier</key><string>io.darkbloom.connect.poc</string>
<key>CFBundleName</key><string>Darkbloom Connect</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
# Local development signature only. This app is a metadata/control companion,
# never an attested provider and never a replacement for the signed worker.
/usr/bin/codesign --force --sign - "$APP_BUNDLE"
if [[ "$MODE" == "--build" ]]; then exit 0; fi
/usr/bin/open -n "$APP_BUNDLE"
if [[ "$MODE" == "--verify" ]]; then
    sleep 1
    while IFS= read -r pid; do
        command_line="$(ps -p "$pid" -o command= || true)"
        if [[ "$command_line" == "$APP_BUNDLE/Contents/MacOS/$APP_NAME" ]]; then exit 0; fi
    done < <(pgrep -x "$APP_NAME" || true)
    echo "This checkout's companion did not launch." >&2
    exit 1
fi
