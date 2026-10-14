#!/usr/bin/env bash
# Local-only packaging; never installs, notarizes, publishes or imports keys.
set -euo pipefail
umask 077
if [[ ${DARKBLOOM_NATIVE_APP_ATTEST_QUALIFICATION:-} != 1 || $# != 6 ]]; then
    printf '%s\n' 'Requires DARKBLOOM_NATIVE_APP_ATTEST_QUALIFICATION=1 and: bin-directory source-matched-metallib new-output-directory profile signing-identity source-version' >&2
    exit 64
fi
script_directory=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source_directory=$(cd "$script_directory/../.." && pwd)
bin_directory=$1
metallib=$2
output=$3
profile=$4
identity=$5
version=$6
[[ -d "$bin_directory" && -s "$metallib" && -s "$profile" && ! -e "$output" && -d "$(dirname "$output")" ]]
output="$(cd "$(dirname "$output")" && pwd -P)/$(basename "$output")"
case "$output" in
    "$source_directory/provider-swift/.build/"*) ;;
    *) printf '%s\n' 'Signed qualification output must be a new directory inside this provider worktree .build' >&2; exit 64 ;;
esac
bash "$source_directory/scripts/check-release-version.sh" "$version"
METALLIB_CACHE_DIR="$source_directory/provider-swift/.build/metallib-cache" \
    bash "$source_directory/scripts/fetch-metallib.sh" "$bin_directory"
cmp -s "$metallib" "$bin_directory/mlx.metallib"
python3 "$source_directory/scripts/provider-signing-validation.py" stage \
    --source "$source_directory" --bin "$bin_directory" --metallib "$metallib" \
    --output "$output" --version "$version"
app="$output/Darkbloom.app"
security cms -D -i "$profile" -o "$output/profile.plist"
python3 "$source_directory/scripts/provider-signing-validation.py" profile --profile "$output/profile.plist"
ditto "$profile" "$app/Contents/embedded.provisionprofile"
python3 "$source_directory/scripts/prepare-app-attest-entitlements.py" \
    --base "$source_directory/provider-swift/entitlements.plist" --profile "$output/profile.plist" \
    --output "$output/signing-entitlements.plist"
codesign --force --options runtime --timestamp --identifier io.darkbloom.fan-helper \
    --sign "$identity" "$app/Contents/Helpers/darkbloom-fan-helper"
codesign --force --options runtime --timestamp --sign "$identity" "$app/Contents/MacOS/mlx.metallib"
codesign --force --options runtime --timestamp \
    --entitlements "$source_directory/provider-swift/entitlements-enclave.plist" \
    --sign "$identity" "$app/Contents/MacOS/darkbloom-enclave"
codesign --force --options runtime --timestamp --entitlements "$output/signing-entitlements.plist" \
    --sign "$identity" "$app/Contents/MacOS/darkbloom"
codesign --force --options runtime --timestamp --entitlements "$output/signing-entitlements.plist" \
    --sign "$identity" "$app"
codesign --verify --deep --strict --verbose=2 "$app"
codesign -d --entitlements "$output/signed-entitlements.plist" --xml "$app/Contents/MacOS/darkbloom"
python3 "$source_directory/scripts/provider-signing-validation.py" cli-entitlements --plist "$output/signed-entitlements.plist"
python3 "$source_directory/scripts/prepare-app-attest-entitlements.py" \
    --base "$source_directory/provider-swift/entitlements.plist" --profile "$output/profile.plist" \
    --output "$output/signing-entitlements.plist" --verify "$output/signed-entitlements.plist"
codesign -d --verbose=4 "$app/Contents/MacOS/darkbloom"
shasum -a 256 "$app/Contents/MacOS/darkbloom" "$app/Contents/MacOS/mlx.metallib"
