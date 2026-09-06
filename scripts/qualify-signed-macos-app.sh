#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)

usage() {
    echo "usage: $0 [--expected-version X.Y.Z] <Darkbloom.app|Darkbloom-macOS-arm64.zip>" >&2
    exit 64
}

fail() {
    echo "signed artifact qualification failed: $*" >&2
    exit 1
}

EXPECTED_VERSION=""
if [ "${1:-}" = "--expected-version" ]; then
    [ "$#" -ge 3 ] || usage
    EXPECTED_VERSION=${2#v}
    shift 2
fi
[ "$#" -eq 1 ] || usage
ARTIFACT=$1

[ "$(uname)" = "Darwin" ] \
    || fail "qualification requires macOS codesign, stapler, and Gatekeeper"
[ -e "$ARTIFACT" ] || fail "artifact does not exist: $ARTIFACT"

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/darkbloom-signed-qualification.XXXXXX")
cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT INT TERM

case "$ARTIFACT" in
    *.zip)
        /usr/bin/ditto -x -k "$ARTIFACT" "$WORK_DIR/archive"
        ROOT_ENTRY_COUNT=$(
            /usr/bin/find "$WORK_DIR/archive" \
                -mindepth 1 -maxdepth 1 -print \
                | /usr/bin/wc -l \
                | /usr/bin/tr -d '[:space:]'
        )
        [ "$ROOT_ENTRY_COUNT" = "1" ] \
            || fail "zip must contain exactly one top-level item"
        APP="$WORK_DIR/archive/Darkbloom.app"
        [ -d "$APP" ] || fail "zip's only top-level item must be Darkbloom.app"
        ;;
    *.app)
        [ -d "$ARTIFACT" ] || fail "app artifact is not a directory: $ARTIFACT"
        APP=$ARTIFACT
        ;;
    *)
        usage
        ;;
esac

INFO_PLIST="$APP/Contents/Info.plist"
APP_BINARY="$APP/Contents/MacOS/DarkbloomApp"
PROVIDER_APP="$APP/Contents/Helpers/DarkbloomProvider.app"
CLI_ALIAS="$APP/Contents/MacOS/darkbloom"
CLI="$PROVIDER_APP/Contents/MacOS/darkbloom"
ENCLAVE="$PROVIDER_APP/Contents/MacOS/darkbloom-enclave"
METALLIB="$PROVIDER_APP/Contents/MacOS/mlx.metallib"
FAN_HELPER="$APP/Contents/Helpers/darkbloom-fan-helper"
PROFILE="$PROVIDER_APP/Contents/embedded.provisionprofile"
APP_REQUIREMENT='anchor apple generic and identifier "io.darkbloom.provider" and certificate leaf[subject.OU] = "SLDQ2GJ6TL"'
FAN_REQUIREMENT='anchor apple generic and identifier "io.darkbloom.fan-helper" and certificate leaf[subject.OU] = "SLDQ2GJ6TL"'
EXPECTED_ACCESS_GROUP='SLDQ2GJ6TL.io.darkbloom.provider'
EXPECTED_APNS_ENVIRONMENT='production' # pragma: allowlist secret

for directory in "$APP/Contents" "$APP/Contents/Helpers" "$PROVIDER_APP" "$PROVIDER_APP/Contents" "$PROVIDER_APP/Contents/MacOS"; do
    [ -d "$directory" ] && [ ! -L "$directory" ] || fail "provider path contains a non-directory or symlink: $directory"
done
[ -L "$CLI_ALIAS" ] || fail "canonical CLI compatibility alias is missing"
[ "$(readlink "$CLI_ALIAS")" = '../Helpers/DarkbloomProvider.app/Contents/MacOS/darkbloom' ] \
    || fail "CLI compatibility alias has an unexpected target"
cmp "$APP/Contents/MacOS/mlx.metallib" "$METALLIB" \
    || fail "outer and runtime metallib bytes differ"
cmp "$APP/Contents/MacOS/darkbloom-enclave" "$ENCLAVE" \
    || fail "outer and runtime enclave bytes differ"
cmp "$APP/Contents/embedded.provisionprofile" "$PROFILE" \
    || fail "outer and helper profiles differ"

[ -f "$INFO_PLIST" ] || fail "Contents/Info.plist is missing"
for executable in "$APP_BINARY" "$CLI" "$ENCLAVE" "$FAN_HELPER"; do
    if [ ! -f "$executable" ] || [ -L "$executable" ] || [ ! -x "$executable" ]; then
        fail "required regular executable is missing: $executable"
    fi
done
[ "$(/usr/bin/stat -f '%Lp' "$FAN_HELPER")" = "755" ] \
    || fail "fan helper mode must be 0755"
if [ ! -f "$METALLIB" ] || [ -L "$METALLIB" ] || [ ! -s "$METALLIB" ]; then
    fail "mlx.metallib is missing, empty, or a symlink"
fi
[ -s "$PROFILE" ] || fail "embedded provisioning profile is missing"

BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")
BUNDLE_EXECUTABLE=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO_PLIST")
SHORT_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")
BUNDLE_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")
[ "$BUNDLE_ID" = "io.darkbloom.provider" ] \
    || fail "unexpected bundle identifier: $BUNDLE_ID"
[ "$BUNDLE_EXECUTABLE" = "DarkbloomApp" ] \
    || fail "unexpected main executable: $BUNDLE_EXECUTABLE"
if ! bash "$ROOT/scripts/install.sh" --semver-test "$SHORT_VERSION"; then
    fail "CFBundleShortVersionString is not canonical SemVer 2: $SHORT_VERSION"
fi
[ "$SHORT_VERSION" = "$BUNDLE_VERSION" ] \
    || fail "short version ($SHORT_VERSION) and bundle version ($BUNDLE_VERSION) differ"
if [ -n "$EXPECTED_VERSION" ]; then
    [ "$SHORT_VERSION" = "$EXPECTED_VERSION" ] \
        || fail "artifact version $SHORT_VERSION does not match expected $EXPECTED_VERSION"
fi

PROVIDER_INFO="$PROVIDER_APP/Contents/Info.plist"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PROVIDER_INFO")" = 'io.darkbloom.provider' ] \
    || fail "unexpected helper bundle identifier"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$PROVIDER_INFO")" = 'darkbloom' ] \
    || fail "provider is not the helper bundle main executable"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROVIDER_INFO")" = "$SHORT_VERSION" ] \
    || fail "helper version differs from outer app"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PROVIDER_INFO")" = "$BUNDLE_VERSION" ] \
    || fail "helper build version differs from outer app"

/usr/bin/codesign --verify --deep --strict --verbose=2 \
    "-R=$APP_REQUIREMENT" "$APP"
/usr/bin/codesign --verify --deep --strict --verbose=2 \
    "-R=$APP_REQUIREMENT" "$PROVIDER_APP"
/usr/bin/codesign --verify --strict --verbose=2 \
    "-R=$APP_REQUIREMENT" "$CLI"
/usr/bin/codesign --verify --strict --verbose=2 \
    "-R=$FAN_REQUIREMENT" "$FAN_HELPER"
for signed_code in "$APP" "$PROVIDER_APP" "$APP_BINARY" "$CLI" "$ENCLAVE" "$FAN_HELPER"; do
    # Drain all diagnostics: grep -q can close early and SIGPIPE codesign,
    # turning a valid runtime flag into a false rejection under pipefail.
    /usr/bin/codesign -dvvv "$signed_code" 2>&1 \
        | /usr/bin/grep -E '^CodeDirectory .*flags=.*runtime' >/dev/null \
        || fail "hardened runtime flag is missing: $signed_code"
done
/usr/bin/xcrun stapler validate "$APP"
/usr/sbin/spctl --assess --type execute --verbose=4 "$APP"

CLI_ENTITLEMENTS="$WORK_DIR/cli-entitlements.plist"
APP_ENTITLEMENTS="$WORK_DIR/app-entitlements.plist"
/usr/bin/codesign -d --entitlements "$CLI_ENTITLEMENTS" --xml "$CLI" 2>/dev/null \
    || true
/usr/bin/codesign -d --entitlements "$APP_ENTITLEMENTS" --xml "$APP_BINARY" 2>/dev/null \
    || true
[ -s "$CLI_ENTITLEMENTS" ] || fail "could not extract CLI entitlements"
[ -s "$APP_ENTITLEMENTS" ] || fail "could not extract app entitlements"

CLI_APS=$(
    /usr/libexec/PlistBuddy \
        -c 'Print :com.apple.developer.aps-environment' \
        "$CLI_ENTITLEMENTS" 2>/dev/null || true
)
[ "$CLI_APS" = "$EXPECTED_APNS_ENVIRONMENT" ] \
    || fail "CLI aps-environment does not match the shipping profile (found ${CLI_APS:-absent})"
/usr/libexec/PlistBuddy -c 'Print :keychain-access-groups' "$CLI_ENTITLEMENTS" \
    | /usr/bin/grep -Fq "$EXPECTED_ACCESS_GROUP" \
    || fail "CLI is missing keychain access group $EXPECTED_ACCESS_GROUP"
if /usr/libexec/PlistBuddy \
    -c 'Print :com.apple.security.get-task-allow' \
    "$CLI_ENTITLEMENTS" >/dev/null 2>&1
then
    fail "CLI carries get-task-allow"
fi

for forbidden in \
    keychain-access-groups \
    com.apple.developer.aps-environment \
    com.apple.application-identifier \
    com.apple.security.get-task-allow
do
    if /usr/libexec/PlistBuddy \
        -c "Print :$forbidden" "$APP_ENTITLEMENTS" >/dev/null 2>&1
    then
        fail "GUI main executable carries restricted entitlement $forbidden"
    fi
done

PROFILE_PLIST="$WORK_DIR/profile.plist"
/usr/bin/security cms -D -i "$PROFILE" > "$PROFILE_PLIST" \
    || fail "embedded provisioning profile cannot be decoded"
PROFILE_APP_ID=$(
    /usr/libexec/PlistBuddy \
        -c 'Print :Entitlements:application-identifier' \
        "$PROFILE_PLIST" 2>/dev/null || true
)
case "$PROFILE_APP_ID" in
    ""|"$EXPECTED_ACCESS_GROUP"|'SLDQ2GJ6TL.*') ;;
    *) fail "profile application-identifier does not authorize the CLI: ${PROFILE_APP_ID:-absent}" ;;
esac
/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier' "$PROFILE_PLIST" \
    | /usr/bin/grep -Fq 'SLDQ2GJ6TL' \
    || fail "profile TeamIdentifier does not include SLDQ2GJ6TL"
PROFILE_APS=$(
    /usr/libexec/PlistBuddy \
        -c 'Print :Entitlements:aps-environment' \
        "$PROFILE_PLIST" 2>/dev/null || true
)
if [ -z "$PROFILE_APS" ]; then
    PROFILE_APS=$(
        /usr/libexec/PlistBuddy \
            -c 'Print :Entitlements:com.apple.developer.aps-environment' \
            "$PROFILE_PLIST" 2>/dev/null || true
    )
fi
[ "$PROFILE_APS" = "$EXPECTED_APNS_ENVIRONMENT" ] \
    || fail "profile aps-environment does not match the shipping value (found ${PROFILE_APS:-absent})"
PROFILE_GROUPS=$(
    /usr/libexec/PlistBuddy \
        -c 'Print :Entitlements:keychain-access-groups' \
        "$PROFILE_PLIST" 2>/dev/null || true
)
printf '%s\n' "$PROFILE_GROUPS" \
    | /usr/bin/grep -Eq 'SLDQ2GJ6TL\.(io\.darkbloom\.provider|\*)' \
    || fail "profile does not authorize keychain access group $EXPECTED_ACCESS_GROUP"

for resource in \
    "$APP/Contents/Resources/Chivo-Regular.ttf" \
    "$APP/Contents/Resources/Chivo-Medium.ttf" \
    "$APP/Contents/Resources/DarkbloomProvider_DarkbloomApp.bundle/default.metallib" \
    "$APP/Contents/Resources/mlx-swift-lm_MLXLMCommon.bundle/pagedattention.metal" \
    "$APP/Contents/Resources/darkbloom-runtime-capabilities/paged-kernel-v1" \
    "$APP/Contents/Resources/darkbloom-runtime-capabilities/fan-helper-v1" \
    "$PROVIDER_APP/Contents/Resources/mlx-swift-lm_MLXLMCommon.bundle/pagedattention.metal" \
    "$PROVIDER_APP/Contents/Resources/darkbloom-runtime-capabilities/paged-kernel-v1"
do
    [ -s "$resource" ] || fail "required sealed resource is missing: $resource"
done

# Static signatures do not prove AMFI accepts restricted entitlements on a
# nested executable. Exercise the actual signed helper without starting a
# provider, touching account/enrollment state, or loading a model.
REPORTED_VERSION=$("$CLI" --version) || fail "signed helper could not launch"
[ "$REPORTED_VERSION" = "$SHORT_VERSION" ] || fail "signed helper version mismatch"
DARKBLOOM_NO_UPDATE_CHECK=1 \
    DARKBLOOM_GEMMA4_PREFILL_CHUNK_EVAL=18 \
    MLX_GEMMA4_FUSED_WEIGHTED_UNSORT=1 \
    MLX_GATHER_QMM_EXPERT_SLICES=1 \
    "$CLI" runtime-smoke || fail "signed helper runtime smoke failed"

echo "Signed Darkbloom artifact qualified non-destructively:"
echo "  Version: $SHORT_VERSION"
echo "  Developer ID requirement: verified"
echo "  Notarization ticket: stapled and valid"
echo "  Gatekeeper assessment: accepted"
echo "  Nested CLI launch and packaged runtime: passed"
echo "  CLI/profile grants: matched; persistent Secure Enclave/APNs still requires live qualification"
