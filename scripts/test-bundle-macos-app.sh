#!/usr/bin/env bash
set -euo pipefail

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/darkbloom-bundle-test.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
BUNDLER="$REPO_ROOT/scripts/bundle-macos-app.sh"
RESOURCE_STAGER="$REPO_ROOT/scripts/stage-swiftpm-resource-bundles.sh"
BIN_DIR="$ROOT/swift bin"
MLX_METALLIB="$ROOT/mlx.metallib"
OUTPUT_PARENT="$ROOT/output with spaces"
APP="$OUTPUT_PARENT/Darkbloom.app"
MANIFEST="$ROOT/resource-manifest.txt"
SHIMS="$ROOT/shims"

mkdir -p \
    "$BIN_DIR/DarkbloomProvider_DarkbloomApp.bundle" \
    "$BIN_DIR/mlx-swift-lm_MLXLMCommon.bundle" \
    "$OUTPUT_PARENT" \
    "$SHIMS"

for product in DarkbloomApp darkbloom darkbloom-enclave darkbloom-fan-helper; do
    printf '#!/bin/sh\nexit 0\n' > "$BIN_DIR/$product"
    chmod +x "$BIN_DIR/$product"
done
printf 'app resource\n' \
    > "$BIN_DIR/DarkbloomProvider_DarkbloomApp.bundle/fixture.txt"
printf 'paged kernel\n' \
    > "$BIN_DIR/mlx-swift-lm_MLXLMCommon.bundle/pagedattention.metal"
printf 'mlx kernels\n' > "$MLX_METALLIB"

# Keep this test independent of Xcode and signing secrets. The bundler only
# needs xcrun to turn one checked-in shader into default.metallib; this shim
# models that output so the complete filesystem assembly can be tested safely.
cat > "$SHIMS/xcrun" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
output=""
while (( $# > 0 )); do
    if [[ $1 == -o ]]; then
        shift
        output=${1:-}
    fi
    shift || true
done
[[ -n $output ]] || { echo "xcrun fixture missing -o" >&2; exit 64; }
printf 'compiled metal fixture\n' > "$output"
SHIM
chmod +x "$SHIMS/xcrun"

# A foreign bundle at the requested output path must survive byte-for-byte.
mkdir -p "$APP/Contents"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.example.foreign</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
printf 'keep me\n' > "$APP/foreign-sentinel"
if PATH="$SHIMS:$PATH" "$BUNDLER" \
    "$BIN_DIR" "$MLX_METALLIB" "$APP" 9.8.7; then
    echo "bundler replaced a foreign output app" >&2
    exit 1
fi
test "$(cat "$APP/foreign-sentinel")" = "keep me"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
    "$APP/Contents/Info.plist")" = "com.example.foreign"

# A known unsigned dev output is ours and may be rebuilt atomically.
/usr/libexec/PlistBuddy -c \
    'Set :CFBundleIdentifier dev.darkbloom.app' "$APP/Contents/Info.plist"
PATH="$SHIMS:$PATH" "$BUNDLER" \
    "$BIN_DIR" "$MLX_METALLIB" "$APP" 9.8.7
"$RESOURCE_STAGER" "$BIN_DIR" "$APP" "$MANIFEST"

test ! -e "$APP/foreign-sentinel"
test -x "$APP/Contents/MacOS/DarkbloomApp"
test -x "$APP/Contents/MacOS/darkbloom"
test -x "$APP/Contents/MacOS/darkbloom-enclave"
test -x "$APP/Contents/Helpers/darkbloom-fan-helper"
test "$(stat -f '%Lp' "$APP/Contents/Helpers/darkbloom-fan-helper")" = "755"
test -s "$APP/Contents/MacOS/mlx.metallib"
test -s "$APP/Contents/Resources/Chivo-Regular.ttf"
test -s "$APP/Contents/Resources/Chivo-Medium.ttf"
test -s "$APP/Contents/Resources/DarkbloomProvider_DarkbloomApp.bundle/default.metallib"
test -s "$APP/Contents/Resources/mlx-swift-lm_MLXLMCommon.bundle/pagedattention.metal"
test "$(tr -d '[:space:]' \
    < "$APP/Contents/Resources/darkbloom-runtime-capabilities/fan-helper-v1")" = "1"
test "$(tr -d '[:space:]' \
    < "$APP/Contents/Resources/darkbloom-runtime-capabilities/paged-kernel-v1")" = "1"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
    "$APP/Contents/Info.plist")" = "io.darkbloom.provider"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' \
    "$APP/Contents/Info.plist")" = "DarkbloomApp"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$APP/Contents/Info.plist")" = "9.8.7"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
    "$APP/Contents/Info.plist")" = "9.8.7"
cmp "$BIN_DIR/darkbloom" "$APP/Contents/MacOS/darkbloom"
cmp "$BIN_DIR/darkbloom-enclave" "$APP/Contents/MacOS/darkbloom-enclave"
cmp "$MLX_METALLIB" "$APP/Contents/MacOS/mlx.metallib"
grep -Fqx 'DarkbloomProvider_DarkbloomApp.bundle' "$MANIFEST"
grep -Fqx 'mlx-swift-lm_MLXLMCommon.bundle' "$MANIFEST"

# The co-bundled CLI remains directly executable regardless of app location.
"$APP/Contents/MacOS/darkbloom" --fixture

# Mirror the workflow's post-staple packaging shape. Signing and stapling are
# intentionally outside this local test, but the downloadable zip must still
# round-trip as exactly one top-level app with its CLI and resources intact.
APP_ARCHIVE="$ROOT/Darkbloom-macOS-arm64.zip"
ARCHIVE_ROOT="$ROOT/archive-root"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$APP_ARCHIVE"
mkdir -p "$ARCHIVE_ROOT"
/usr/bin/ditto -x -k "$APP_ARCHIVE" "$ARCHIVE_ROOT"
ROOT_ENTRY_COUNT=$(/usr/bin/find "$ARCHIVE_ROOT" \
    -mindepth 1 -maxdepth 1 -print | wc -l | tr -d '[:space:]')
test "$ROOT_ENTRY_COUNT" = "1"
ARCHIVED_APP="$ARCHIVE_ROOT/Darkbloom.app"
test -d "$ARCHIVED_APP"
cmp "$APP/Contents/MacOS/darkbloom" \
    "$ARCHIVED_APP/Contents/MacOS/darkbloom"
cmp "$APP/Contents/MacOS/DarkbloomApp" \
    "$ARCHIVED_APP/Contents/MacOS/DarkbloomApp"
test -s "$ARCHIVED_APP/Contents/Resources/DarkbloomProvider_DarkbloomApp.bundle/default.metallib"
test -s "$ARCHIVED_APP/Contents/Resources/mlx-swift-lm_MLXLMCommon.bundle/pagedattention.metal"

shopt -s nullglob
leftovers=(
    "$OUTPUT_PARENT"/.Darkbloom.app.staging.*
    "$OUTPUT_PARENT"/.Darkbloom.app.backup.*
)
(( ${#leftovers[@]} == 0 )) || {
    printf 'bundle assembly left temporary paths:\n%s\n' "${leftovers[*]}" >&2
    exit 1
}

echo "macOS app bundle assembly tests passed"
