#!/usr/bin/env bash
# Select the image's Xcode 27 tools or an explicitly selected SDK 27 CLT.
# Keep Xcode selected for Metal/signing; scope this wrapper to Swift builds/tests.
set -euo pipefail
: "${GITHUB_ENV:?}"
: "${GITHUB_PATH:?}"
: "${RUNNER_TEMP:?}"
: "${GITHUB_WORKSPACE:?}"
if [[ -n "${DARKBLOOM_RELEASE_TOOLCHAIN_ROOT:-}" ]]; then
  toolchain="$DARKBLOOM_RELEASE_TOOLCHAIN_ROOT"
  sdk="${DARKBLOOM_RELEASE_SDK_ROOT:-$toolchain/SDKs/MacOSX27.0.sdk}"
else
  # Do not set DEVELOPER_DIR before checkout: a runner image may select Xcode
  # through a different app path, and /usr/bin/git itself uses xcrun.
  selected_developer="${DEVELOPER_DIR:-$(xcode-select -p)}"
  if [[ "$selected_developer" == /Library/Developer/CommandLineTools ]]; then
    toolchain="$selected_developer"
    sdk="${DARKBLOOM_RELEASE_SDK_ROOT:-$toolchain/SDKs/MacOSX27.0.sdk}"
  else
    xcodebuild -version
    compiler=$(xcrun --sdk macosx --find swift)
    toolchain="${compiler%/usr/bin/swift}"
    sdk="${DARKBLOOM_RELEASE_SDK_ROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
  fi
fi

ready() {
  [[ -x "$toolchain/usr/bin/swift" && -f "$sdk/SDKSettings.json" ]] || return 1
  local toolchain_version
  toolchain_version=$("$toolchain/usr/bin/swift" --version) || return 1
  grep -qE 'Apple Swift version 6\.4([.[:space:]]|$)' <<< "$toolchain_version" || return 1
  python3 - "$sdk/SDKSettings.json" <<'PY'
import json, sys
if json.load(open(sys.argv[1]))['Version'] not in ('27.0', '27.0.0'):
    raise SystemExit('Provider release requires the macOS 27.0 SDK')
PY
}

if ! ready; then
  echo 'Provider release requires preinstalled SDK 27 / Swift 6.4; select an Xcode 27 image or SDK 27 CLT' >&2
  exit 1
fi

wrapper_dir="$RUNNER_TEMP/darkbloom-release-toolchain/bin"
mkdir -p "$wrapper_dir"
ln -sf "$GITHUB_WORKSPACE/scripts/provider-release-swift.sh" "$wrapper_dir/swift"
{
  echo "PROVIDER_SWIFT=$toolchain/usr/bin/swift"
  echo "PROVIDER_SDKROOT=$sdk"
  echo 'PROVIDER_SDK_VERSION=27.0'
} >> "$GITHUB_ENV"
echo "$wrapper_dir" >> "$GITHUB_PATH"
echo 'Selected provider release SDK 27.0 and Swift 6.4'
"$toolchain/usr/bin/swift" --version
