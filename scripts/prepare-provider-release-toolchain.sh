#!/usr/bin/env bash
# Select SDK 27 for App Attest's current code measurements. Install only the
# Apple-offered Command Line Tools package, and only on a GitHub Actions runner.
# Keep Xcode selected for Metal/signing; the wrapper scopes this to Swift builds.
set -euo pipefail
: "${GITHUB_ENV:?}"
: "${GITHUB_PATH:?}"
: "${RUNNER_TEMP:?}"
: "${GITHUB_WORKSPACE:?}"
toolchain="${DARKBLOOM_RELEASE_TOOLCHAIN_ROOT:-/Library/Developer/CommandLineTools}"
sdk="${DARKBLOOM_RELEASE_SDK_ROOT:-$toolchain/SDKs/MacOSX27.0.sdk}"

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
  if [[ "${GITHUB_ACTIONS:-false}" != true || "$toolchain" != /Library/Developer/CommandLineTools || "$sdk" != "$toolchain/SDKs/MacOSX27.0.sdk" ]]; then
    echo 'SDK 27 / Swift 6.4 unavailable; automatic installation is limited to the default CI toolchain' >&2
    exit 1
  fi
  sudo /usr/sbin/softwareupdate --install 'Command Line Tools for Xcode 27.0-27.0' --verbose
  ready
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
