#!/bin/bash
# usage: run-tests.sh OUT_DIR
# Runs the already-built test bundles (no compile) and the worker's startup
# checks. The bundles are whatever build-tests.sh last built: rebuild after any
# source change and compare the test counts.
set -uo pipefail
. "$(dirname "$0")/env.sh"
export PATH=$T/tools/native-swift:$PATH; out=$1; mkdir -p "$out"
products=$(swift build --package-path $W/libs/darkbloom-cluster --show-bin-path)
bundle="$products/DarkbloomClusterRuntimeTests.xctest/Contents/MacOS"
cp "$METALLIB" "$products/mlx.metallib"; cp "$METALLIB" "$bundle/mlx.metallib"
swift test --package-path $W/libs/darkbloom-cluster --skip-build 2>&1 | scrub > "$out/library-tests.log"; echo "library tests exit=${PIPESTATUS[0]}"
rm -f "$bundle/mlx.metallib"
grep -E "Test run with|Executed [0-9]+ tests|✘|error:|failed" "$out/library-tests.log" | tail -25
swift test --package-path $W/libs/darkbloom-cluster-worker --skip-build --triple arm64-apple-macosx26.2 2>&1 | scrub > "$out/worker-tests.log"; echo "worker tests exit=${PIPESTATUS[0]}"
grep -E "Test run with|Executed [0-9]+ tests|✘|error:|failed" "$out/worker-tests.log" | tail -25
worker=$(swift build --package-path $W/libs/darkbloom-cluster-worker --scratch-path $W/libs/darkbloom-cluster-worker/.build-native-worker -c release --show-bin-path --triple arm64-apple-macosx26.2)/darkbloom-cluster-worker
bash $W/libs/darkbloom-cluster-worker/Tests/StartupChecks/run.sh "$worker" 2>&1 | scrub > "$out/startup-checks.log"; echo "startup checks exit=${PIPESTATUS[0]}"; tail -3 "$out/startup-checks.log"
git -C $W rev-parse HEAD > "$out/source-head.txt"
