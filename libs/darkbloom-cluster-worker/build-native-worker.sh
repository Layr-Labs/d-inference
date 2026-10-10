#!/bin/bash
# Build one product of the native cluster worker package with a macOS 26.2
# deployment target, so the pinned Cmlx compiles the real JACCL backend, then
# refuse the result unless it actually contains JACCL and is a 26.2 Mach-O.
set -euo pipefail
if [[ $# != 4 ]]; then
  echo 'usage: build-native-worker.sh NATIVE_WORKER_PACKAGE_DIR PRODUCT MATCHED_METALLIB EXPECTED_METALLIB_SHA256' >&2
  exit 2
fi
worker_package_dir="$1"
product="$2"
matched_metallib="$3"
metallib_sha="$4"
if [[ "$(basename "$worker_package_dir")" != darkbloom-cluster-worker ||
      ! -f "$worker_package_dir/Package.swift" ||
      ! -f "$worker_package_dir/../darkbloom-cluster/Package.swift" ||
      ! "$product" =~ ^darkbloom-cluster-[a-z-]+$ ||
      ! -f "$matched_metallib" || ! "$metallib_sha" =~ ^[0-9a-f]{64}$ ]]; then
  echo 'Expected the sibling native-worker package, one of its products and an explicitly pinned source-matched metallib' >&2
  exit 2
fi
actual_sha="$(shasum -a 256 "$matched_metallib" | cut -d ' ' -f 1)"
if [[ "$actual_sha" != "$metallib_sha" ]]; then
  echo 'Source-matched metallib pin differs' >&2
  exit 1
fi
scratch_path="$worker_package_dir/.build-native-worker"
jobs="${DARKBLOOM_CLUSTER_WORKER_BUILD_JOBS:-2}"
# Both compilation and final linker deployment are 26.2. The shared library
# package and normal ProviderCore retain macOS 14; no Mach-O rewriting is used.
swift build --package-path "$worker_package_dir" --scratch-path "$scratch_path" \
  -c release --jobs "$jobs" --disable-automatic-resolution --skip-update --disable-build-manifest-caching \
  --product "$product" --triple arm64-apple-macosx26.2 \
  -Xcc -target -Xcc arm64-apple-macosx26.2 >&2
binary_dir="$(swift build --package-path "$worker_package_dir" --scratch-path "$scratch_path" \
  -c release --show-bin-path --triple arm64-apple-macosx26.2)"
binary="$binary_dir/$product"
# The pair driver is control only: it must link no MLX at all, so it has no
# JACCL backend to verify and needs no Metal library beside it.
case "$product" in
  darkbloom-cluster-pair-check) links_mlx=0 ;;
  *) links_mlx=1 ;;
esac
# Read all of nm's output: an early-exiting match would fail the pipeline.
if [[ "$links_mlx" == 1 ]]; then
  if [[ "$(nm -a "$binary" | grep -c 'JACCLGroup')" == 0 ]]; then
    echo 'Product linked a JACCL stub; it is not a native RDMA build' >&2
    exit 1
  fi
elif [[ "$(nm -a "$binary" | grep -c -e 'JACCLGroup' -e 'mlx_array_')" != 0 ]]; then
  echo 'Control-only product links MLX' >&2
  exit 1
fi
build_version="$(/usr/bin/xcrun vtool -show-build "$binary")"
# Exactly one macOS LC_BUILD_VERSION and exact 26.2 minimum. A matching SDK or
# 26.2 object target alone is insufficient; this rejects a minos-14 binary.
if ! printf '%s\n' "$build_version" | /usr/bin/awk '
  $1 == "cmd" && $2 == "LC_BUILD_VERSION" { commands++ }
  $1 == "platform" { platforms++; if ($2 != "MACOS") bad = 1 }
  $1 == "minos" { minima++; if ($2 != "26.2" && $2 != "26.2.0") bad = 1 }
  END { exit !(commands == 1 && platforms == 1 && minima == 1 && !bad) }
'; then
  printf '%s\n' "$build_version" >&2
  echo 'Product Mach-O deployment minimum is not exactly macOS 26.2' >&2
  exit 1
fi
printf '%s\n' "$build_version" >&2
if [[ "$links_mlx" == 0 ]]; then
  printf '%s\n' "$binary"
  exit 0
fi
destination_metallib="$binary_dir/mlx.metallib"
if [[ -L "$destination_metallib" || ( -e "$destination_metallib" && ! -f "$destination_metallib" ) ]]; then
  echo 'Refusing a linked or nonregular metallib destination' >&2
  exit 1
fi
# A prior verified bundle can be read-only. Reuse matching bytes; replace only
# this owned build artifact when the explicitly selected source has changed.
if [[ ! -f "$destination_metallib" ]] ||
   [[ "$(shasum -a 256 "$destination_metallib" | cut -d ' ' -f 1)" != "$metallib_sha" ]]; then
  cp -f "$matched_metallib" "$destination_metallib"
fi
actual_sha="$(shasum -a 256 "$binary_dir/mlx.metallib" | cut -d ' ' -f 1)"
if [[ "$actual_sha" != "$metallib_sha" ]]; then
  echo 'Copied metallib pin differs' >&2
  exit 1
fi
printf '%s\n' "$binary"
