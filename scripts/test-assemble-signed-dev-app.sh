#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
script="$root/scripts/assemble-signed-dev-app.sh"
[[ -x $script ]] || { echo "dev bundle assembler is not executable" >&2; exit 1; }
bash -n "$script"

contract=$($script --print-contract)
for required in \
    'app=Darkbloom.app/Contents/MacOS/darkbloom' \
    'worker=Darkbloom.app/Contents/XPCServices/DarkbloomInferenceWorker.xpc/Contents/MacOS/darkbloom-inference-worker' \
    'worker_id=io.darkbloom.provider.inference-worker' \
    'team_id=SLDQ2GJ6TL' \
    'worker_entitlements=application-identifier,keychain-access-groups,com.apple.security.app-sandbox,com.apple.security.files.bookmarks.app-scope' \
    'worker_resources=Contents/MacOS/mlx.metallib,Contents/Resources/mlx-swift-lm_MLXLMCommon.bundle/pagedattention.metal'
do
    grep -Fqx "$required" <<< "$contract"
done

for required_source in \
    'security cms -D -i "$main_profile"' \
    'security cms -D -i "$worker_profile"' \
    '"application-identifier": "SLDQ2GJ6TL.io.darkbloom.provider.inference-worker"' \
    '"keychain-access-groups": ["SLDQ2GJ6TL.io.darkbloom.provider"]' \
    '"com.apple.security.app-sandbox": True' \
    '"com.apple.security.files.bookmarks.app-scope": True' \
    'codesign --force --options runtime --timestamp' \
    'certificate leaf[subject.OU] = \"$TEAM_ID\"' \
    'EXPECTED="$work/main-entitlements.plist" ACTUAL="$work/signed-main-entitlements.plist"' \
    'codesign --force --options runtime --timestamp=none' \
    'DARKBLOOM_SIGNED_HOST_TEST=1 "$worker" --sandbox-self-test-v1'
do
    grep -Fq -- "$required_source" "$script"
done

if grep -Fq -- '--sign -' "$script"; then
    echo "dev bundle assembler permits ad-hoc signing" >&2
    exit 1
fi
if grep -Eq -- '--(fallback|skip-sign|ad-hoc)' "$script"; then
    echo "dev bundle assembler exposes a signing or inference bypass flag" >&2
    exit 1
fi

worker_sign_line=$(grep -nF 'sign --identifier "$WORKER_ID"' "$script" | sed -n '1s/:.*//p')
outer_sign_line=$(grep -nF 'sign --entitlements "$work/main-entitlements.plist" "$app"' "$script" | sed -n '1s/:.*//p')
[[ -n $worker_sign_line && -n $outer_sign_line && $worker_sign_line -lt $outer_sign_line ]] || {
    echo "nested worker is not signed before the outer app" >&2
    exit 1
}

if "$script" >/dev/null 2>&1; then
    echo "dev bundle assembler accepted absent signing/profile inputs" >&2
    exit 1
fi
if "$script" --identity - --main-profile missing --worker-profile missing \
    --metallib missing >/dev/null 2>&1
then
    echo "dev bundle assembler accepted ad-hoc identity" >&2
    exit 1
fi

echo "signed dev app assembly contract checks passed"
