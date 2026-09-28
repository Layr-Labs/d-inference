#!/usr/bin/env bash
# Run one explicitly reviewed GPU-global test in its own Swift test process.
# The caller must own the GPU test lane and have staged the matching metallib.
# No weight downloads or model-server lifecycle operations occur here.
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 <exclusive-test-function>" >&2
    exit 2
fi
case "$1" in
    evaluatedPagesAvoidDoubleTaxAndRetainedAliasKeepsPressure|decodeBatchCompositionInvariance) ;;
    *) echo "unreviewed exclusive GPU test selector: $1" >&2; exit 2 ;;
esac

script_directory=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
exec env DARKBLOOM_EXCLUSIVE_NATIVE_GPU_TEST=1 \
    "$script_directory/run-nested-suite.sh" "$1" --no-parallel
