#!/usr/bin/env bash
# Select the provider's Xcode 27 Swift toolchain and macOS SDK, or an
# explicitly selected SDK 27 CLT. Keep the same Xcode selected for Metal and
# signing: when this script picks another installed Xcode than the image's, it
# exports DEVELOPER_DIR for the later steps. Scope the swift wrapper to Swift
# builds and tests.
#
# DARKBLOOM_PROVIDER_TOOLCHAIN chooses what is accepted:
#   release (release builds, release qualification, signing): SDK 27.2 and
#     Swift 6.4.2 (Xcode 27.2) only.
#   qualification (default: provider CI, and the Darkbloom macOS CI base check
#     that runs this script): SDK 27.2 or 27.0 and Swift 6.4.x. SDK 27.0
#     (Xcode 27.1) stays accepted only while the production CI base is on
#     Xcode 27.1.
# Darkbloom Sandbox's images/macos/pins.env mirrors the qualification values.
set -euo pipefail
: "${GITHUB_ENV:?}"
: "${GITHUB_PATH:?}"
: "${RUNNER_TEMP:?}"
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

case "${DARKBLOOM_PROVIDER_TOOLCHAIN:-qualification}" in
  release)
    sdk_versions=(27.2)
    swift_version=6.4.2
    ;;
  qualification)
    sdk_versions=(27.2 27.0)
    swift_version=6.4
    ;;
  *)
    echo "Unknown DARKBLOOM_PROVIDER_TOOLCHAIN: ${DARKBLOOM_PROVIDER_TOOLCHAIN}" >&2
    exit 2
    ;;
esac
sdk_list=${sdk_versions[*]}
requirement="SDK ${sdk_list// / or } / Swift $swift_version"

# Prints the accepted SDK version of an SDK directory, normalized (27.2.0 is
# 27.2), or fails.
sdk_version() {
  [[ -f "$1/SDKSettings.json" ]] || return 1
  python3 - "$1/SDKSettings.json" "${sdk_versions[@]}" <<'PY'
import json, sys
def parts(text):
    numbers = [int(part) for part in str(text).split('.')]
    return numbers + [0] * (3 - len(numbers))
try:
    found = parts(json.load(open(sys.argv[1]))['Version'])
except (OSError, ValueError, KeyError, TypeError):
    raise SystemExit(1)
for accepted in sys.argv[2:]:
    if parts(accepted) == found:
        print(accepted)
        raise SystemExit(0)
raise SystemExit(1)
PY
}

# Succeeds when $toolchain has the required Swift and $sdk an accepted SDK;
# sets $selected_sdk_version.
ready() {
  [[ -x "$toolchain/usr/bin/swift" ]] || return 1
  local toolchain_version found
  toolchain_version=$("$toolchain/usr/bin/swift" --version 2>/dev/null) || return 1
  # Swift 6.4 accepts 6.4 and 6.4.x; Swift 6.4.2 accepts 6.4.2 and 6.4.2.x.
  [[ "$toolchain_version" =~ Apple\ Swift\ version\ ([0-9][0-9.]*[0-9]) ]] || return 1
  found=${BASH_REMATCH[1]}
  [[ "$found" == "$swift_version" || "$found" == "$swift_version".* ]] || return 1
  selected_sdk_version=$(sdk_version "$sdk") || return 1
}

# Points $toolchain and $sdk at an Xcode developer directory.
use_xcode() {
  local compiler
  compiler=$(DEVELOPER_DIR="$1" xcrun --sdk macosx --find swift 2>/dev/null) || return 1
  toolchain="${compiler%/usr/bin/swift}"
  sdk="${DARKBLOOM_RELEASE_SDK_ROOT:-$(DEVELOPER_DIR="$1" xcrun --sdk macosx --show-sdk-path 2>/dev/null)}" || return 1
}

# A CLT keeps one SDK per version: take the first accepted one it has.
clt_sdk() {
  local version
  for version in "${sdk_versions[@]}"; do
    if [[ -d "$1/SDKs/MacOSX$version.sdk" ]]; then
      echo "$1/SDKs/MacOSX$version.sdk"
      return
    fi
  done
  echo "$1/SDKs/MacOSX.sdk"
}

# Tries the image's Xcode, then every installed Xcode, newest first. An
# explicit DEVELOPER_DIR is the only candidate. Selects the first one with the
# preferred SDK, else the first one with another accepted SDK; sets
# $selected_developer, $toolchain and $sdk, or clears $toolchain.
select_xcode() {
  local candidates=("$image_developer") app candidate fallback=""
  if [[ -z "${DEVELOPER_DIR:-}" ]]; then
    while IFS= read -r app; do
      [[ -n "$app" ]] && candidates+=("$app/Contents/Developer")
    done < <(find "$xcode_applications" -maxdepth 1 -name 'Xcode*.app' -type d 2>/dev/null | sort -rV)
  fi
  for candidate in "${candidates[@]}"; do
    use_xcode "$candidate" && ready || continue
    if [[ "$selected_sdk_version" == "${sdk_versions[0]}" ]]; then
      selected_developer="$candidate"
      break
    fi
    [[ -n "$fallback" ]] || fallback="$candidate"
  done
  [[ -n "$selected_developer" ]] || selected_developer="$fallback"
  toolchain=""
  [[ -n "$selected_developer" ]] || return 0
  # Later candidates replaced $toolchain and $sdk: point them at the selection again.
  use_xcode "$selected_developer"
  ready
  DEVELOPER_DIR="$selected_developer" xcodebuild -version
}

xcode_applications="${DARKBLOOM_XCODE_APPLICATIONS:-/Applications}"
image_developer=""
selected_developer=""
selected_sdk_version=""
toolchain_root="${DARKBLOOM_RELEASE_TOOLCHAIN_ROOT:-}"
if [[ -z "$toolchain_root" ]]; then
  # Do not set DEVELOPER_DIR before checkout: a runner image may select Xcode
  # through a different app path, and /usr/bin/git itself uses xcrun.
  image_developer="${DEVELOPER_DIR:-$(xcode-select -p)}"
  if [[ "$image_developer" == /Library/Developer/CommandLineTools ]]; then
    toolchain_root="$image_developer"
  fi
fi
if [[ -n "$toolchain_root" ]]; then
  toolchain="$toolchain_root"
  sdk="${DARKBLOOM_RELEASE_SDK_ROOT:-$(clt_sdk "$toolchain")}"
  ready || toolchain=""
else
  select_xcode
fi

if [[ -z "$toolchain" ]]; then
  echo "Provider release requires preinstalled $requirement; select an Xcode 27 image or SDK 27 CLT" >&2
  for app in "$xcode_applications"/Xcode*.app; do
    [[ -d "$app" ]] && echo "installed: $app" >&2
  done
  exit 1
fi

wrapper_dir="$RUNNER_TEMP/darkbloom-release-toolchain/bin"
mkdir -p "$wrapper_dir"
ln -sf "$script_dir/provider-release-swift.sh" "$wrapper_dir/swift"
{
  if [[ -n "$selected_developer" && "$selected_developer" != "$image_developer" ]]; then
    echo "DEVELOPER_DIR=$selected_developer"
  fi
  echo "PROVIDER_SWIFT=$toolchain/usr/bin/swift"
  echo "PROVIDER_SDKROOT=$sdk"
  echo "PROVIDER_SDK_VERSION=$selected_sdk_version"
} >> "$GITHUB_ENV"
echo "$wrapper_dir" >> "$GITHUB_PATH"
echo "Selected provider release SDK $selected_sdk_version and Swift $swift_version"
"$toolchain/usr/bin/swift" --version
