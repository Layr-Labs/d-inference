#!/usr/bin/env bash
# Use the exact Kitware binary distribution for release Metal builds.
set -euo pipefail

if [ "$(uname -s)-$(uname -m)" != Darwin-arm64 ]; then
  echo 'Release CMake bootstrap requires an Apple Silicon Mac' >&2
  exit 2
fi

version=3.31.12
# Darkbloom macOS images unpack this same sha256-checked archive into the
# runner tool cache (darkbloom-sandbox images/macos/guest/provision.sh,
# cmake_toolcache). Use that copy rather than downloading 80 MB again; download
# everywhere else, such as on Blacksmith.
cached="${RUNNER_TOOL_CACHE:-/nonexistent}/cmake/$version/universal"
if [ -f "$cached.complete" ] &&
    [ "$("$cached/CMake.app/Contents/bin/cmake" --version 2>/dev/null | head -n 1)" = "cmake version $version" ]; then
  cmake_bin="$cached/CMake.app/Contents/bin"
  echo "Using CMake $version from the runner tool cache"
else
  archive="$(mktemp)"
  trap 'rm -f "$archive"' EXIT
  curl --fail --silent --show-error --location --retry 3 \
    "https://github.com/Kitware/CMake/releases/download/v$version/cmake-$version-macos-universal.tar.gz" \
    --output "$archive"
  printf '%s  %s\n' \
    '799af7fd545db9bf1b9cfe72f8095880e727a2d4e0df0e3dffc3bc7b95c2d3b0' \
    "$archive" | shasum -a 256 --check
  install_root="$RUNNER_TEMP/cmake-$version"
  mkdir -p "$install_root"
  tar -xzf "$archive" -C "$install_root"
  cmake_bin="$install_root/cmake-$version-macos-universal/CMake.app/Contents/bin"
fi
"$cmake_bin/cmake" --version
printf '%s\n' "$cmake_bin" >> "$GITHUB_PATH"
