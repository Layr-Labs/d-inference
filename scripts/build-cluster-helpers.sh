#!/bin/bash
# Build the two cluster helpers the release ships inside Darkbloom.app and put
# them, with the files they load at run time, in one flat directory that
# `provider-signing-validation.py stage --cluster-helpers` copies into
# `Darkbloom.app/Contents/Helpers`:
#
#   darkbloom-cluster-worker   the rank a cluster member launches
#   darkbloom-cluster-plan     the placement tool the setup runs beside it
#   mlx.metallib               the SAME source-matched Metal library as
#                              Contents/MacOS/mlx.metallib (MLX loads the copy
#                              beside the executable; the bytes must match)
#   pagedattention.metal       the paged-attention source the worker compiles
#                              at run time (beside the executable, as the
#                              native worker build places it)
#
# The products are built by the worker package's own native build
# (libs/darkbloom-cluster-worker/build-native-worker.sh: macOS 26.2 Mach-O,
# real JACCL backend, pinned metallib), unsigned. Signing is a separate step
# (scripts/sign-cluster-helpers.sh) that needs the Developer ID identity.
#
# usage: build-cluster-helpers.sh MATCHED_METALLIB OUTPUT_DIR
set -euo pipefail
if [[ $# != 2 ]]; then
  echo 'usage: build-cluster-helpers.sh MATCHED_METALLIB OUTPUT_DIR' >&2
  exit 2
fi
metallib="$1"
output="$2"
repo="$(cd "$(dirname "$0")/.." && pwd)"
worker_package="$repo/libs/darkbloom-cluster-worker"
if [[ ! -f "$metallib" || -L "$metallib" || ! -s "$metallib" ]]; then
  echo 'The matched metallib must be a regular, nonempty file' >&2
  exit 2
fi
if [[ -e "$output" ]]; then
  echo "Refusing to reuse an existing output directory: $output" >&2
  exit 2
fi
metallib_sha="$(shasum -a 256 "$metallib" | cut -d ' ' -f 1)"
mkdir -p "$output"
binary_dir=""
for product in darkbloom-cluster-worker darkbloom-cluster-plan; do
  binary="$("$worker_package/build-native-worker.sh" "$worker_package" "$product" "$metallib" "$metallib_sha")"
  if [[ ! -f "$binary" || -L "$binary" || ! -x "$binary" ]]; then
    echo "The native build did not produce a regular executable for $product" >&2
    exit 1
  fi
  this_dir="$(dirname "$binary")"
  if [[ -n "$binary_dir" && "$this_dir" != "$binary_dir" ]]; then
    echo 'The two products were built into different directories' >&2
    exit 1
  fi
  binary_dir="$this_dir"
  cp -f "$binary" "$output/$product"
  chmod 0755 "$output/$product"
done
for resource in mlx.metallib pagedattention.metal; do
  source="$binary_dir/$resource"
  if [[ ! -f "$source" || -L "$source" || ! -s "$source" ]]; then
    echo "The native build left no regular $resource beside the products" >&2
    exit 1
  fi
  cp -f "$source" "$output/$resource"
  chmod 0644 "$output/$resource"
done
if [[ "$(shasum -a 256 "$output/mlx.metallib" | cut -d ' ' -f 1)" != "$metallib_sha" ]]; then
  echo 'The helpers metallib differs from the matched metallib' >&2
  exit 1
fi
printf '%s\n' "$output"
