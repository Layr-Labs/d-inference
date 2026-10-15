#!/bin/bash
set -euo pipefail
if [[ $# != 3 ]]; then
  echo 'usage: build-native-worker.sh PACKAGE_DIR MATCHED_METALLIB EXPECTED_METALLIB_SHA256' >&2
  exit 2
fi
package_dir="$1"
matched_metallib="$2"
metallib_sha="$3"
if [[ ! -f "$package_dir/Package.swift" || ! -f "$matched_metallib" || ! "$metallib_sha" =~ ^[0-9a-f]{64}$ ]]; then
  echo 'Expected an assembled worker package and explicitly pinned source-matched metallib' >&2
  exit 2
fi
actual_sha="$(shasum -a 256 "$matched_metallib" | cut -d ' ' -f 1)"
if [[ "$actual_sha" != "$metallib_sha" ]]; then
  echo 'Source-matched metallib pin differs' >&2
  exit 1
fi
scratch_path="$package_dir/.build-native-worker"
# Cmlx's conditional JACCL implementation needs the C++ deployment target too.
# This is a separate executable build; the normal provider remains macOS 14.
swift build --package-path "$package_dir" --scratch-path "$scratch_path" \
  -c release --jobs 2 --disable-automatic-resolution --skip-update \
  --product darkbloom-cluster-worker --triple arm64-apple-macosx26.2 \
  -Xcc -target -Xcc arm64-apple-macosx26.2
binary_dir="$(swift build --package-path "$package_dir" --scratch-path "$scratch_path" \
  -c release --show-bin-path --triple arm64-apple-macosx26.2)"
if ! nm -a "$binary_dir/darkbloom-cluster-worker" | rg 'JACCLGroup' > /dev/null; then
  echo 'Worker linked a JACCL stub; it is not a native RDMA worker' >&2
  exit 1
fi
cp "$matched_metallib" "$binary_dir/mlx.metallib"
actual_sha="$(shasum -a 256 "$binary_dir/mlx.metallib" | cut -d ' ' -f 1)"
if [[ "$actual_sha" != "$metallib_sha" ]]; then
  echo 'Copied metallib pin differs' >&2
  exit 1
fi
printf '%s\n' "$binary_dir/darkbloom-cluster-worker"
