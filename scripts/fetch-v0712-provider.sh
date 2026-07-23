#!/bin/bash
set -euo pipefail

CACHE_DIR=${1:-${DARKBLOOM_RELEASE_TEST_CACHE:-${TMPDIR:-/tmp}/darkbloom-release-test-cache}}
VERSION=0.7.12
URL=https://pub-3d1cb668259340eeb2276e1d375c846d.r2.dev/releases/v0.7.12/darkbloom-bundle-macos-arm64.tar.gz
BUNDLE_SHA256=92fadb451ee1776457e9b410b6915857239b066d605067ddf50ba4e971af2f88
BINARY_SHA256=c74b4829454bc4e2e40a0d9791458d17ba3dd278a5238ec628145b172016584d
METALLIB_SHA256=e2d5853b79925b3661861fed79f30b1aeb636a52ebbde15b054711ce865edfaa

ARCHIVE="$CACHE_DIR/v$VERSION/darkbloom-bundle-macos-arm64.tar.gz"
EXTRACTED="$CACHE_DIR/v$VERSION/extracted"
mkdir -p "$(dirname "$ARCHIVE")"

sha256() {
    shasum -a 256 "$1" | awk '{print $1}'
}

if [ ! -f "$ARCHIVE" ] || [ "$(sha256 "$ARCHIVE")" != "$BUNDLE_SHA256" ]; then
    tmp="$ARCHIVE.tmp.$$"
    trap 'rm -f "$tmp"' EXIT
    curl --fail --silent --show-error --location "$URL" --output "$tmp"
    [ "$(sha256 "$tmp")" = "$BUNDLE_SHA256" ] || {
        echo "released v$VERSION bundle SHA-256 mismatch" >&2
        exit 1
    }
    mv "$tmp" "$ARCHIVE"
    trap - EXIT
fi

rm -rf "$EXTRACTED.tmp"
mkdir -p "$EXTRACTED.tmp"
tar xzf "$ARCHIVE" -C "$EXTRACTED.tmp"
BIN="$EXTRACTED.tmp/Darkbloom.app/Contents/MacOS/darkbloom"
METALLIB="$EXTRACTED.tmp/Darkbloom.app/Contents/MacOS/mlx.metallib"
[ -x "$BIN" ] || { echo "released provider binary missing" >&2; exit 1; }
[ -f "$METALLIB" ] || { echo "released metallib missing" >&2; exit 1; }
[ "$(sha256 "$BIN")" = "$BINARY_SHA256" ] || {
    echo "released v$VERSION binary SHA-256 mismatch" >&2
    exit 1
}
# These optional wire fields first ship in v0.7.13. Proving their marker strings
# are absent from the hash-pinned v0.7.12 executable distinguishes true omission
# from an authoritative empty telemetry snapshot.
for marker in prefix_cache_statuses prefix_cache_donation_outcomes; do
    if LC_ALL=C grep -a -q -F "$marker" "$BIN"; then
        echo "released v$VERSION unexpectedly contains candidate telemetry marker $marker" >&2
        exit 1
    fi
done
[ "$(sha256 "$METALLIB")" = "$METALLIB_SHA256" ] || {
    echo "released v$VERSION metallib SHA-256 mismatch" >&2
    exit 1
}
rm -rf "$EXTRACTED"
mv "$EXTRACTED.tmp" "$EXTRACTED"
echo "$EXTRACTED/Darkbloom.app/Contents/MacOS/darkbloom"
