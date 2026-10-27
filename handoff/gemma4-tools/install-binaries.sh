#!/bin/bash
# Copies the four built products, the metallib and the resource bundles into
# T/bin/gemma4 and writes their hashes and the source head beside them. Refuses
# while a process started from that directory is alive.
set -uo pipefail
. "$(dirname "$0")/env.sh"
export PATH=$T/tools/native-swift:$PATH
if pgrep -f "$B/darkbloom-cluster-" > /dev/null; then echo "a process from $B is running; not replacing its binaries" | scrub; exit 20; fi
products=$(swift build --package-path $W/libs/darkbloom-cluster-worker --scratch-path $W/libs/darkbloom-cluster-worker/.build-native-worker -c release --show-bin-path --triple arm64-apple-macosx26.2)
mkdir -p "$B"
for f in darkbloom-cluster-stage-check darkbloom-cluster-reference darkbloom-cluster-worker darkbloom-cluster-pair-check mlx.metallib; do
  [ -e "$products/$f" ] || { echo "missing product: $f"; exit 21; }
  cp -f "$products/$f" "$B/$f.new" && mv -f "$B/$f.new" "$B/$f"
done
for bundle in "$products"/*.bundle; do rm -rf "$B/$(basename "$bundle")"; cp -R "$bundle" "$B/"; done
[ "$(shasum -a 256 "$B/mlx.metallib" | cut -d' ' -f1)" = "$METALLIB_SHA256" ] || { echo "metallib is not the pinned one"; exit 22; }
git -C $W rev-parse HEAD > "$B/SOURCE-HEAD.txt"
git -C $W/libs/mlx-swift/Source/Cmlx/mlx rev-parse HEAD > "$B/MLX-HEAD.txt"
(cd "$B" && shasum -a 256 darkbloom-cluster-* mlx.metallib | tee SHA256SUMS.txt)
echo "source $(cat "$B/SOURCE-HEAD.txt"), MLX $(cat "$B/MLX-HEAD.txt")"
