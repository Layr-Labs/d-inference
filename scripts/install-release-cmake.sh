#!/usr/bin/env bash
# Use the exact Kitware binary distribution for release Metal builds.
set -euo pipefail

if [ "$(uname -s)-$(uname -m)" != Darwin-arm64 ]; then
  echo 'Release CMake bootstrap requires an Apple Silicon Mac' >&2
  exit 2
fi

archive="$(mktemp)"
trap 'rm -f "$archive"' EXIT
curl --fail --silent --show-error --location --retry 3 \
  https://github.com/Kitware/CMake/releases/download/v3.31.12/cmake-3.31.12-macos-universal.tar.gz \
  --output "$archive"
printf '%s  %s\n' \
  '799af7fd545db9bf1b9cfe72f8095880e727a2d4e0df0e3dffc3bc7b95c2d3b0' \
  "$archive" | shasum -a 256 --check
install_root="$RUNNER_TEMP/cmake-3.31.12"
mkdir -p "$install_root"
tar -xzf "$archive" -C "$install_root"
cmake_bin="$install_root/cmake-3.31.12-macos-universal/CMake.app/Contents/bin"
"$cmake_bin/cmake" --version
printf '%s\n' "$cmake_bin" >> "$GITHUB_PATH"
