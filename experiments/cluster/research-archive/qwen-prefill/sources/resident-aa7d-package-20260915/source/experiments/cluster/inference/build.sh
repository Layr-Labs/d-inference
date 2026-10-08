#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

python3 prepare_dependencies.py

# SwiftPM still uses each dependency's minimum target despite --triple. Override
# clang's target explicitly; -mmacosx-version-min loses to SwiftPM's -target.
swift build -c release --jobs 2 --disable-automatic-resolution --skip-update --product cluster-inference \
  --triple arm64-apple-macosx26.2 \
  -Xcc -target -Xcc arm64-apple-macosx26.2

binary_dir="$(swift build -c release --show-bin-path --triple arm64-apple-macosx26.2)"
metallib="${CLUSTER_METALLIB:-../../../provider-swift/.build/debug/mlx.metallib}"
if [[ ! -f "$metallib" ]]; then
  echo "Missing source-matched metallib; build the provider or set CLUSTER_METALLIB" >&2
  exit 1
fi
cp "$metallib" "$binary_dir/mlx.metallib"

# JACCLGroup only exists in the real backend, not the no_jaccl stub.
if ! nm -a "$binary_dir/cluster-inference" | rg 'JACCLGroup' > /dev/null; then
  echo "Cmlx did not link the real JACCL implementation" >&2
  exit 1
fi
if ! nm -a "$binary_dir/cluster-inference" | rg 'N3mlx4core11distributed4ring9RingGroup' > /dev/null; then
  echo "Cmlx did not link the real loopback-test ring implementation" >&2
  exit 1
fi
"$binary_dir/cluster-inference" --mode capability
echo "$binary_dir/cluster-inference" >&2
