#!/bin/bash
set -euo pipefail
if [[ $# != 3 ]]; then
  echo 'usage: build-native-worker.sh NATIVE_WORKER_PACKAGE_DIR MATCHED_METALLIB EXPECTED_METALLIB_SHA256' >&2
  exit 2
fi
worker_package_dir="$1"
matched_metallib="$2"
metallib_sha="$3"
if [[ "$(basename "$worker_package_dir")" != darkbloom-cluster-worker ||
      ! -f "$worker_package_dir/Package.swift" ||
      ! -f "$worker_package_dir/../darkbloom-cluster/Package.swift" ||
      ! -f "$worker_package_dir/Sources/DarkbloomClusterWorker/WorkerMain.swift" ||
      ! -f "$matched_metallib" || ! "$metallib_sha" =~ ^[0-9a-f]{64}$ ]]; then
  echo 'Expected the isolated sibling native-worker package and an explicitly pinned source-matched metallib' >&2
  exit 2
fi
actual_sha="$(shasum -a 256 "$matched_metallib" | cut -d ' ' -f 1)"
if [[ "$actual_sha" != "$metallib_sha" ]]; then
  echo 'Source-matched metallib pin differs' >&2
  exit 1
fi
scratch_path="$worker_package_dir/.build-native-worker"
# Both compilation and final linker deployment are 26.2. The shared library
# package and normal ProviderCore retain macOS 14; no Mach-O rewriting is used.
swift build --package-path "$worker_package_dir" --scratch-path "$scratch_path" \
  -c release --jobs 2 --disable-automatic-resolution --skip-update \
  --product darkbloom-cluster-worker --triple arm64-apple-macosx26.2 \
  -Xcc -target -Xcc arm64-apple-macosx26.2
binary_dir="$(swift build --package-path "$worker_package_dir" --scratch-path "$scratch_path" \
  -c release --show-bin-path --triple arm64-apple-macosx26.2)"
binary="$binary_dir/darkbloom-cluster-worker"
if ! nm -a "$binary" | rg 'JACCLGroup' > /dev/null; then
  echo 'Worker linked a JACCL stub; it is not a native RDMA worker' >&2
  exit 1
fi
build_version="$(/usr/bin/xcrun vtool -show-build "$binary")"
# Exactly one macOS LC_BUILD_VERSION and exact 26.2 minimum. A matching SDK or
# 26.2 object target alone is insufficient; this rejects the old minos14 binary.
if ! printf '%s\n' "$build_version" | /usr/bin/awk '
  $1 == "cmd" && $2 == "LC_BUILD_VERSION" { commands++ }
  $1 == "platform" { platforms++; if ($2 != "MACOS") bad = 1 }
  $1 == "minos" { minima++; if ($2 != "26.2" && $2 != "26.2.0") bad = 1 }
  END { exit !(commands == 1 && platforms == 1 && minima == 1 && !bad) }
'; then
  printf '%s\n' "$build_version" >&2
  echo 'Worker Mach-O deployment minimum is not exactly macOS 26.2' >&2
  exit 1
fi
printf '%s\n' "$build_version" >&2
cp "$matched_metallib" "$binary_dir/mlx.metallib"
actual_sha="$(shasum -a 256 "$binary_dir/mlx.metallib" | cut -d ' ' -f 1)"
if [[ "$actual_sha" != "$metallib_sha" ]]; then
  echo 'Copied metallib pin differs' >&2
  exit 1
fi
printf '%s\n' "$binary"
