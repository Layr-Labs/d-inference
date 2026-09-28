#!/usr/bin/env bash
# Run from the already-built SDK package with the matched metallib staged.
# Keep ordinary kernel parity and GPU-global composition checks independent.
set -uo pipefail
script_directory=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
paged_test_status=0

env -u DARKBLOOM_EXCLUSIVE_NATIVE_GPU_TEST \
    "$script_directory/run-nested-suite.sh" CBv2PagedKernelTests --no-parallel \
    --skip decodeBatchCompositionInvariance || paged_test_status=$?

# Run even when the remaining suite fails; neither gate may hide the other.
"$script_directory/run-exclusive-native-gpu-test.sh" \
    decodeBatchCompositionInvariance || paged_test_status=$?
exit "$paged_test_status"
