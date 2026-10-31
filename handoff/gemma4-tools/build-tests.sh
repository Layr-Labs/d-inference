#!/bin/bash
# Compile only: the library's and the worker package's test bundles.
set -uo pipefail
. "$(dirname "$0")/env.sh"
export PATH=$T/tools/native-swift:$PATH
status=0
echo "== library tests build $(date -u +%H:%M:%SZ)"
swift build --package-path $W/libs/darkbloom-cluster --build-tests -j 8 2>&1 | grep -E "error|Build complete" | scrub | tail -40
[[ ${PIPESTATUS[0]} == 0 ]] || { echo "BUILD FAILED: library tests"; status=1; }
echo "== worker tests build $(date -u +%H:%M:%SZ)"
swift build --package-path $W/libs/darkbloom-cluster-worker --build-tests -j 8 --triple arm64-apple-macosx26.2 -Xcc -target -Xcc arm64-apple-macosx26.2 2>&1 | grep -E "error|Build complete" | scrub | tail -40
[[ ${PIPESTATUS[0]} == 0 ]] || { echo "BUILD FAILED: worker tests"; status=1; }
echo "tests-build-exit=$status $(date -u +%H:%M:%SZ)"
exit $status
