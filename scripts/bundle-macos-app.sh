#!/usr/bin/env bash
set -euo pipefail

# Assemble the release Darkbloom.app bundle: the SwiftUI DarkbloomApp as the
# main executable with the provider CLI co-bundled in Contents/MacOS.
#
# This is the extraction target for the release pipeline: CI
# (.github/workflows/release-swift.yml) calls this script to produce the
# unsigned app, then signs, notarizes, and staples it. script/build_and_run.sh
# deliberately does NOT call this script: it is a dev-only launcher whose
# unsigned app keeps the dev bundle id (dev.darkbloom.app), while this script
# stamps the release identity documented below.
#
# Usage:
#   scripts/bundle-macos-app.sh <swift-bin-dir> <mlx.metallib> <output-app> <version>
#
# Requirements: macOS with the full Xcode toolchain (xcrun metal/metallib for
# the SpatialField shader) and a prior `swift build` of the DarkbloomApp,
# darkbloom, darkbloom-enclave, and darkbloom-fan-helper products into
# <swift-bin-dir>.

# ─────────────────────────────────────────────────────────────────────────
# Release bundle identity.
#
# The release app's bundle id MUST remain io.darkbloom.provider (NOT
# dev.darkbloom.app from provider-swift/Resources/DarkbloomApp/Info.plist and
# NOT ai.darkbloom.app). Four separate security/ops contracts pin it:
#   1. provider-swift/Sources/ProviderCore/Update/DarkbloomCodeSignature.swift
#      — the provider self-updater refuses a downloaded bundle whose
#      designated requirement is not `identifier "io.darkbloom.provider"`.
#   2. scripts/install.sh DARKBLOOM_DESIGNATED_REQUIREMENT — pinned by
#      scripts/test-install-atomic.sh as an exact-match line.
#   3. The embedded provisioning profile authorizes keychain-access-group
#      SLDQ2GJ6TL.io.darkbloom.provider and aps-environment=production ONLY
#      for this app id (see release-swift.yml profile verification).
#   4. APNs topic: coordinator default (cmd/coordinator/main.go) and the
#      provider CLI's code identity both resolve to io.darkbloom.provider.
# Renaming the app is a multi-component security migration (new App ID,
# profile, coordinator topic default, self-updater constant) — do not do it
# here.
APP_BUNDLE_ID="io.darkbloom.provider"
# NOTE (signing lives in release-swift.yml, not here): once DarkbloomApp
# becomes the bundle's main executable, the co-bundled CLI is nested code and
# MUST be signed with an explicit --identifier "io.darkbloom.provider". When
# the CLI was the legacy wrapper's main executable, codesign derived that
# identifier from the bundle Info.plist; as nested code it would otherwise
# derive a basename-based identifier (verified locally) — a silent identity
# change breaking fan-helper XPC authorization, the APNs topic match, and the
# keychain access group pin.

APP_PROCESS_NAME="DarkbloomApp"
CLI_NAME="darkbloom"
ENCLAVE_NAME="darkbloom-enclave"
FAN_HELPER_NAME="darkbloom-fan-helper"
RESOURCE_BUNDLE_NAME="DarkbloomProvider_DarkbloomApp.bundle"

if [[ $# -ne 4 ]]; then
    echo "usage: $0 <swift-bin-dir> <mlx.metallib> <output-app> <version>" >&2
    exit 64
fi

BIN_DIR=$1
MLX_METALLIB=$2
OUTPUT_APP=$3
VERSION=$4

[[ $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]] || {
    echo "Invalid version: $VERSION" >&2
    exit 64
}
[[ "$OUTPUT_APP" == *.app ]] || {
    echo "Output must be a .app bundle: $OUTPUT_APP" >&2
    exit 64
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PACKAGE_DIR="$ROOT_DIR/provider-swift"
SHADER_SOURCE="$PACKAGE_DIR/Sources/DarkbloomApp/Resources/DarkbloomSpatialField.metal"
APP_INFO_PLIST_SOURCE="$PACKAGE_DIR/Resources/DarkbloomApp/Info.plist"
FONT_DIR="$PACKAGE_DIR/Resources/DarkbloomApp"
RESOURCE_BUNDLE="$BIN_DIR/$RESOURCE_BUNDLE_NAME"

# An explicit output path is still not permission to delete an unrelated app.
# Rebuild release/dev Darkbloom outputs in place; refuse files, symlinks,
# malformed bundles, and bundles carrying any other identifier.
if [[ -e "$OUTPUT_APP" || -L "$OUTPUT_APP" ]]; then
    if [[ ! -d "$OUTPUT_APP" || -L "$OUTPUT_APP" ]]; then
        echo "Refusing to replace non-bundle output: $OUTPUT_APP" >&2
        exit 1
    fi
    EXISTING_BUNDLE_ID=$(/usr/libexec/PlistBuddy \
        -c 'Print :CFBundleIdentifier' \
        "$OUTPUT_APP/Contents/Info.plist" 2>/dev/null || true)
    case "$EXISTING_BUNDLE_ID" in
        "$APP_BUNDLE_ID"|dev.darkbloom.app) ;;
        *)
            echo "Refusing to replace foreign app at $OUTPUT_APP (id: ${EXISTING_BUNDLE_ID:-missing})" >&2
            exit 1
            ;;
    esac
fi

for required in \
    "$BIN_DIR/$APP_PROCESS_NAME" \
    "$BIN_DIR/$CLI_NAME" \
    "$BIN_DIR/$ENCLAVE_NAME" \
    "$BIN_DIR/$FAN_HELPER_NAME" \
    "$RESOURCE_BUNDLE" \
    "$MLX_METALLIB" \
    "$SHADER_SOURCE" \
    "$APP_INFO_PLIST_SOURCE" \
    "$FONT_DIR/Chivo-Regular.ttf" \
    "$FONT_DIR/Chivo-Medium.ttf"
do
    [[ -e "$required" ]] || { echo "Missing required input: $required" >&2; exit 1; }
done

# SwiftPM's CLI does not compile Metal shaders into resource bundles. Compile
# the SpatialField shader into the SwiftPM app resource bundle in <bin-dir>
# BEFORE scripts/stage-swiftpm-resource-bundles.sh copies that bundle into
# Contents/Resources, so there is exactly one canonical copy (same ordering
# contract as script/build_and_run.sh).
SHADER_AIR="$RESOURCE_BUNDLE/DarkbloomSpatialField.air"
xcrun -sdk macosx metal -c "$SHADER_SOURCE" -o "$SHADER_AIR"
xcrun -sdk macosx metallib "$SHADER_AIR" -o "$RESOURCE_BUNDLE/default.metallib"
rm -f "$SHADER_AIR"

# ─── Assemble ─────────────────────────────────────────────────────────
APP_PARENT=$(dirname "$OUTPUT_APP")
APP_NAME=$(basename "$OUTPUT_APP")
mkdir -p "$APP_PARENT"
STAGING_ROOT=$(mktemp -d "$APP_PARENT/.${APP_NAME}.staging.XXXXXX")
BACKUP_ROOT=""
APP="$STAGING_ROOT/$APP_NAME"

cleanup() {
    local status=$?
    if [[ -n "$BACKUP_ROOT" \
        && -e "$BACKUP_ROOT/$APP_NAME" \
        && ! -e "$OUTPUT_APP" ]]; then
        mv "$BACKUP_ROOT/$APP_NAME" "$OUTPUT_APP" 2>/dev/null || true
    fi
    rm -rf "$STAGING_ROOT"
    if [[ -n "$BACKUP_ROOT" && -e "$OUTPUT_APP" ]]; then
        rm -rf "$BACKUP_ROOT"
    fi
    return "$status"
}
trap cleanup EXIT

mkdir -p \
    "$APP/Contents/MacOS" \
    "$APP/Contents/Helpers" \
    "$APP/Contents/Resources/darkbloom-runtime-capabilities"

# Main executable + co-bundled CLI payload. DarkbloomCLILocator probes
# Contents/MacOS/darkbloom inside the app bundle FIRST, so the CLI must live
# here (identical bytes to the flat bin/ verifier copies: CI cmp-enforces).
cp "$BIN_DIR/$APP_PROCESS_NAME" "$APP/Contents/MacOS/$APP_PROCESS_NAME"
cp "$BIN_DIR/$CLI_NAME" "$APP/Contents/MacOS/$CLI_NAME"
cp "$BIN_DIR/$ENCLAVE_NAME" "$APP/Contents/MacOS/$ENCLAVE_NAME"
cp "$MLX_METALLIB" "$APP/Contents/MacOS/mlx.metallib"
chmod +x \
    "$APP/Contents/MacOS/$APP_PROCESS_NAME" \
    "$APP/Contents/MacOS/$CLI_NAME" \
    "$APP/Contents/MacOS/$ENCLAVE_NAME"

# Dormant opt-in root helper (same contract as the legacy bundle: sealed
# under Contents/Helpers with a capability marker).
install -m 0755 \
    "$BIN_DIR/$FAN_HELPER_NAME" \
    "$APP/Contents/Helpers/$FAN_HELPER_NAME"
printf '1\n' \
    > "$APP/Contents/Resources/darkbloom-runtime-capabilities/fan-helper-v1"

# App UI resources (fonts at Contents/Resources root, Info.plist stamped with
# the release identity; SwiftPM .*bundle payloads are staged by
# scripts/stage-swiftpm-resource-bundles.sh afterwards).
cp "$FONT_DIR/Chivo-Regular.ttf" "$APP/Contents/Resources/Chivo-Regular.ttf"
cp "$FONT_DIR/Chivo-Medium.ttf" "$APP/Contents/Resources/Chivo-Medium.ttf"
cp "$APP_INFO_PLIST_SOURCE" "$APP/Contents/Info.plist"

/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $APP_BUNDLE_ID" \
    "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" \
    "$APP/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" \
        "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $VERSION" \
    "$APP/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" \
        "$APP/Contents/Info.plist"

BUNDLE_EXECUTABLE=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' \
    "$APP/Contents/Info.plist")
[[ "$BUNDLE_EXECUTABLE" == "$APP_PROCESS_NAME" ]] || {
    echo "Info.plist CFBundleExecutable must be $APP_PROCESS_NAME, got $BUNDLE_EXECUTABLE" >&2
    exit 1
}

if [[ -e "$OUTPUT_APP" ]]; then
    BACKUP_ROOT=$(mktemp -d "$APP_PARENT/.${APP_NAME}.backup.XXXXXX")
    mv "$OUTPUT_APP" "$BACKUP_ROOT/$APP_NAME"
fi
mv "$APP" "$OUTPUT_APP"

echo "Assembled $OUTPUT_APP (id $APP_BUNDLE_ID, version $VERSION)"
