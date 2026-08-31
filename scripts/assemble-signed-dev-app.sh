#!/usr/bin/env bash
set -euo pipefail

TEAM_ID=SLDQ2GJ6TL
APP_ID=io.darkbloom.provider
WORKER_ID=io.darkbloom.provider.inference-worker
WORKER_BUNDLE_NAME=DarkbloomInferenceWorker.xpc
WORKER_NAME=darkbloom-inference-worker
CLI_NAME=darkbloom
ENCLAVE_NAME=darkbloom-enclave
FAN_HELPER_NAME=darkbloom-fan-helper
SANDBOX_SENTINEL=DBXPC_SANDBOX_SELF_TEST_V1:63

usage() {
    cat >&2 <<'USAGE'
usage: scripts/assemble-signed-dev-app.sh \
  --identity <Apple Development or Developer ID identity> \
  --main-profile <provisionprofile> \
  --worker-profile <provisionprofile> \
  --metallib <mlx.metallib> \
  [--configuration debug|release] [--output <Darkbloom.app>] [--version <version>]

Builds all four Swift products and assembles a signed app-host/XPC development
bundle. Ad-hoc signing, missing profiles, wildcard worker identities, and
in-process fallback are not supported. The output path is printed on success.
USAGE
    exit 64
}

if [[ ${1:-} == --print-contract ]]; then
    cat <<'CONTRACT'
app=Darkbloom.app/Contents/MacOS/darkbloom
worker=Darkbloom.app/Contents/XPCServices/DarkbloomInferenceWorker.xpc/Contents/MacOS/darkbloom-inference-worker
worker_id=io.darkbloom.provider.inference-worker
team_id=SLDQ2GJ6TL
worker_entitlements=application-identifier,keychain-access-groups,com.apple.security.app-sandbox,com.apple.security.files.bookmarks.app-scope
worker_resources=Contents/MacOS/mlx.metallib,Contents/Resources/mlx-swift-lm_MLXLMCommon.bundle/pagedattention.metal
CONTRACT
    exit 0
fi

identity=
main_profile=
worker_profile=
metallib=
configuration=debug
output=
version=0.0.0
while (( $# > 0 )); do
    case $1 in
        --identity) identity=${2:-}; shift 2 ;;
        --main-profile) main_profile=${2:-}; shift 2 ;;
        --worker-profile) worker_profile=${2:-}; shift 2 ;;
        --metallib) metallib=${2:-}; shift 2 ;;
        --configuration) configuration=${2:-}; shift 2 ;;
        --output) output=${2:-}; shift 2 ;;
        --version) version=${2:-}; shift 2 ;;
        *) usage ;;
    esac
done

[[ -n $identity && $identity != - ]] || {
    echo "error: --identity must name an explicit Apple Development or Developer ID signing identity; ad-hoc signing is forbidden" >&2
    exit 64
}
[[ $identity == Apple\ Development:* || $identity == Developer\ ID\ Application:* ]] || {
    echo "error: signing identity must be Apple Development or Developer ID Application" >&2
    exit 64
}
[[ -f $main_profile && ! -L $main_profile && -s $main_profile ]] || {
    echo "error: --main-profile must be a nonempty regular provisioning profile" >&2
    exit 64
}
[[ -f $worker_profile && ! -L $worker_profile && -s $worker_profile ]] || {
    echo "error: --worker-profile must be a nonempty regular provisioning profile" >&2
    exit 64
}
[[ -f $metallib && ! -L $metallib && -s $metallib ]] || {
    echo "error: --metallib must be a nonempty regular source-matched mlx.metallib" >&2
    exit 64
}
[[ $configuration == debug || $configuration == release ]] || usage
[[ $version =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || {
    echo "error: --version must contain one to three numeric components: $version" >&2
    exit 64
}

root=$(cd "$(dirname "$0")/.." && pwd)
provider="$root/provider-swift"
[[ -d $provider ]] || { echo "error: provider-swift directory is missing" >&2; exit 1; }
if [[ -z $output ]]; then
    output="$provider/.build/dev-app/Darkbloom.app"
fi
[[ $(basename "$output") == Darkbloom.app ]] || {
    echo "error: --output must end in Darkbloom.app" >&2
    exit 64
}

old_umask=$(umask)
umask 077
work=$(mktemp -d "${TMPDIR:-/tmp}/darkbloom-dev-bundle.XXXXXX")
umask "$old_umask"
chmod 0700 "$work"
[[ ! -L $work && $(stat -f '%Lp' "$work") == 700 && $(stat -f '%u' "$work") == $(id -u) ]] || {
    echo "error: private assembly workspace validation failed" >&2
    exit 1
}
cleanup() { rm -rf -- "$work"; }
trap cleanup EXIT HUP INT TERM

security cms -D -i "$main_profile" > "$work/main-profile.plist" || {
    echo "error: main profile is not a valid Apple CMS provisioning profile" >&2
    exit 1
}
security cms -D -i "$worker_profile" > "$work/worker-profile.plist" || {
    echo "error: worker profile is not a valid Apple CMS provisioning profile" >&2
    exit 1
}
PROFILE_DIR=$work SIGNING_IDENTITY=$identity python3 - <<'PY'
import os
import plistlib
import sys
from datetime import datetime, timezone

root = os.environ["PROFILE_DIR"]
with open(os.path.join(root, "main-profile.plist"), "rb") as stream:
    main = plistlib.load(stream)
with open(os.path.join(root, "worker-profile.plist"), "rb") as stream:
    worker = plistlib.load(stream)

errors = []
for label, profile in (("main", main), ("worker", worker)):
    if profile.get("TeamIdentifier") != ["SLDQ2GJ6TL"]:
        errors.append(f"{label} profile TeamIdentifier must be exactly ['SLDQ2GJ6TL']")
    expiry = profile.get("ExpirationDate")
    if expiry is None:
        errors.append(f"{label} profile has no ExpirationDate")
    else:
        now = datetime.now(timezone.utc)
        if expiry.tzinfo is None:
            expiry = expiry.replace(tzinfo=timezone.utc)
        if expiry <= now:
            errors.append(f"{label} profile expired at {expiry.isoformat()}")

main_entitlements = main.get("Entitlements", {})
if main_entitlements.get("application-identifier") != "SLDQ2GJ6TL.io.darkbloom.provider":
    errors.append("main profile application-identifier must be exact")
if main_entitlements.get("keychain-access-groups") != ["SLDQ2GJ6TL.io.darkbloom.provider"]:
    errors.append("main profile keychain-access-groups must be the exact provider group")
aps = main_entitlements.get("aps-environment") or main_entitlements.get(
    "com.apple.developer.aps-environment"
)
expected_aps = (
    "development"
    if os.environ["SIGNING_IDENTITY"].startswith("Apple Development:")
    else "production"
)
if aps != expected_aps:
    errors.append(
        f"main profile must grant aps-environment={expected_aps} "
        f"for this signing identity; got {aps!r}"
    )

worker_entitlements = worker.get("Entitlements", {})
expected_worker = {
    "application-identifier": "SLDQ2GJ6TL.io.darkbloom.provider.inference-worker",
    "keychain-access-groups": ["SLDQ2GJ6TL.io.darkbloom.provider"],
    "com.apple.security.app-sandbox": True,
    "com.apple.security.files.bookmarks.app-scope": True,
}
for key, expected in expected_worker.items():
    if worker_entitlements.get(key) != expected:
        errors.append(
            f"worker profile {key} must be {expected!r}; got {worker_entitlements.get(key)!r}"
        )

if errors:
    for error in errors:
        print(f"error: {error}", file=sys.stderr)
    sys.exit(1)
PY

swift build --package-path "$provider" -c "$configuration" --product "$CLI_NAME"
swift build --package-path "$provider" -c "$configuration" --product "$ENCLAVE_NAME"
swift build --package-path "$provider" -c "$configuration" --product "$FAN_HELPER_NAME"
swift build --package-path "$provider" -c "$configuration" --product "$WORKER_NAME"

install -m 0600 "$root/scripts/entitlements.plist" \
    "$work/main-entitlements.plist"
if [[ $identity == Apple\ Development:* ]]; then
    /usr/libexec/PlistBuddy -c \
        'Set :com.apple.developer.aps-environment development' \
        "$work/main-entitlements.plist"
fi
bin_dir=$(swift build --package-path "$provider" -c "$configuration" --show-bin-path)
for executable in "$CLI_NAME" "$ENCLAVE_NAME" "$FAN_HELPER_NAME" "$WORKER_NAME"; do
    [[ -x $bin_dir/$executable ]] || {
        echo "error: build did not produce $bin_dir/$executable" >&2
        exit 1
    }
done

app="$work/Darkbloom.app"
xpc="$app/Contents/XPCServices/$WORKER_BUNDLE_NAME"
worker="$xpc/Contents/MacOS/$WORKER_NAME"
mkdir -p \
    "$app/Contents/MacOS" \
    "$app/Contents/Helpers" \
    "$app/Contents/Resources/darkbloom-runtime-capabilities" \
    "$xpc/Contents/MacOS" \
    "$xpc/Contents/Resources/mlx-swift-lm_MLXLMCommon.bundle"
install -m 0755 "$bin_dir/$CLI_NAME" "$app/Contents/MacOS/$CLI_NAME"
install -m 0755 "$bin_dir/$ENCLAVE_NAME" "$app/Contents/MacOS/$ENCLAVE_NAME"
install -m 0755 "$bin_dir/$FAN_HELPER_NAME" "$app/Contents/Helpers/$FAN_HELPER_NAME"
install -m 0755 "$bin_dir/$WORKER_NAME" "$worker"
install -m 0644 "$metallib" "$xpc/Contents/MacOS/mlx.metallib"
install -m 0644 "$root/scripts/inference-worker-Info.plist" "$xpc/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $version" "$xpc/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$xpc/Contents/Info.plist"
paged_source="$bin_dir/mlx-swift-lm_MLXLMCommon.bundle/pagedattention.metal"
[[ -f $paged_source && ! -L $paged_source && -s $paged_source ]] || {
    echo "error: build output is missing the exact pagedattention.metal resource: $paged_source" >&2
    exit 1
}
install -m 0644 "$paged_source" \
    "$xpc/Contents/Resources/mlx-swift-lm_MLXLMCommon.bundle/pagedattention.metal"
install -m 0644 "$main_profile" "$app/Contents/embedded.provisionprofile"
install -m 0644 "$worker_profile" "$xpc/Contents/embedded.provisionprofile"
printf '1\n' > "$app/Contents/Resources/darkbloom-runtime-capabilities/fan-helper-v1"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$APP_ID</string>
<key>CFBundleExecutable</key><string>$CLI_NAME</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>$version</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleName</key><string>Darkbloom</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST

sign() {
    if [[ $identity == Apple\ Development:* ]]; then
        codesign --force --options runtime --timestamp=none \
            --sign "$identity" "$@"
    else
        codesign --force --options runtime --timestamp \
            --sign "$identity" "$@"
    fi
}
sign "$xpc/Contents/MacOS/mlx.metallib"
sign --identifier "$WORKER_ID" \
    --entitlements "$root/scripts/inference-worker-entitlements.plist" "$worker"
sign --identifier "$WORKER_ID" \
    --entitlements "$root/scripts/inference-worker-entitlements.plist" "$xpc"
sign --identifier io.darkbloom.fan-helper "$app/Contents/Helpers/$FAN_HELPER_NAME"
sign --entitlements "$provider/entitlements-enclave.plist" "$app/Contents/MacOS/$ENCLAVE_NAME"
sign --entitlements "$work/main-entitlements.plist" "$app/Contents/MacOS/$CLI_NAME"
sign --entitlements "$work/main-entitlements.plist" "$app"

worker_requirement="anchor apple generic and identifier \"$WORKER_ID\" and certificate leaf[subject.OU] = \"$TEAM_ID\""
fan_requirement="anchor apple generic and identifier \"io.darkbloom.fan-helper\" and certificate leaf[subject.OU] = \"$TEAM_ID\""
app_requirement="anchor apple generic and identifier \"$APP_ID\" and certificate leaf[subject.OU] = \"$TEAM_ID\""
codesign --verify --deep --strict --verbose=2 "-R=$worker_requirement" "$xpc"
codesign --verify --strict --verbose=2 "-R=$worker_requirement" "$worker"
codesign --verify --deep --strict --verbose=2 "-R=$app_requirement" "$app"
codesign --verify --strict --verbose=2 "-R=$fan_requirement" \
    "$app/Contents/Helpers/$FAN_HELPER_NAME"
codesign -d --entitlements "$work/worker-entitlements.plist" --xml "$worker" 2>/dev/null
EXPECTED="$root/scripts/inference-worker-entitlements.plist" ACTUAL="$work/worker-entitlements.plist" python3 - <<'PY'
import os
import plistlib
with open(os.environ["EXPECTED"], "rb") as stream:
    expected = plistlib.load(stream)
with open(os.environ["ACTUAL"], "rb") as stream:
    actual = plistlib.load(stream)
if actual != expected:
    raise SystemExit(f"error: signed worker entitlement drift: {actual!r}")
PY

codesign -d --entitlements "$work/signed-main-entitlements.plist" --xml \
    "$app/Contents/MacOS/$CLI_NAME" 2>/dev/null
EXPECTED="$work/main-entitlements.plist" ACTUAL="$work/signed-main-entitlements.plist" python3 - <<'PY'
import os
import plistlib
with open(os.environ["EXPECTED"], "rb") as stream:
    expected = plistlib.load(stream)
with open(os.environ["ACTUAL"], "rb") as stream:
    actual = plistlib.load(stream)
if actual != expected:
    raise SystemExit(f"error: signed app-host entitlement drift: {actual!r}")
PY

[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$xpc/Contents/Info.plist") == "$WORKER_ID" ]]
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$xpc/Contents/Info.plist") == "$WORKER_NAME" ]]
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$xpc/Contents/Info.plist") == XPC! ]]
[[ $(/usr/libexec/PlistBuddy -c 'Print :XPCService:ServiceType' "$xpc/Contents/Info.plist") == Application ]]
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$xpc/Contents/Info.plist") == "$version" ]]
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$xpc/Contents/Info.plist") == "$version" ]]
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist") == "$APP_ID" ]]
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist") == "$version" ]]
[[ -f $app/Contents/embedded.provisionprofile && ! -L $app/Contents/embedded.provisionprofile ]]
[[ -f $xpc/Contents/embedded.provisionprofile && ! -L $xpc/Contents/embedded.provisionprofile ]]
[[ -z $(find "$xpc/Contents/Resources" -mindepth 1 \
    ! -path "$xpc/Contents/Resources/mlx-swift-lm_MLXLMCommon.bundle" \
    ! -path "$xpc/Contents/Resources/mlx-swift-lm_MLXLMCommon.bundle/pagedattention.metal" \
    -print -quit) ]]
sandbox_output=$(DARKBLOOM_SIGNED_HOST_TEST=1 "$worker" --sandbox-self-test-v1)
[[ $sandbox_output == "$SANDBOX_SENTINEL" ]] || {
    echo "error: signed worker sandbox probe returned ${sandbox_output:-<empty>}, expected $SANDBOX_SENTINEL" >&2
    exit 1
}

mkdir -p "$(dirname "$output")"
rm -rf -- "$output"
/bin/mv "$app" "$output"
trap - EXIT HUP INT TERM
cleanup
printf '%s\n' "$output"
