#!/usr/bin/env bash
# Run from provider-swift after building tests and staging the matched metallib.
# Allocator, interleaving, environment, stage-deadline and URLSession mock
# cases need fresh processes. Every isolated suite still has a non-zero/no-skip gate.
# Keep both outcomes: a failure in the general suite must not silence this gate.
set -uo pipefail
script_directory=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
provider_test_status=0
isolated_filters=(
  emptyNativePoolTeardownUsesActualRetiredAdapter
  processLedgerCannotCombineOldUsageWithNewMaterializationCredit
  defaultApplyProjectsSettings
  stageDelta
  SpecDecHuggingFaceTests
)
isolated_pattern=$(IFS='|'; printf '%s' "${isolated_filters[*]}")
isolated_pattern="ProcessMemoryNativeIntegrationTests|${isolated_pattern}"
# Swift Testing otherwise overlaps independent suites sharing process-wide MLX
# state and cooperative-executor capacity. Tests still create their own tasks
# and controlled interleavings; only unrelated test cases run sequentially.
env -u DARKBLOOM_EXCLUSIVE_NATIVE_GPU_TEST \
  swift test --skip-build --no-parallel --skip "$isolated_pattern" || provider_test_status=$?
for test_filter in "${isolated_filters[@]}"; do
  env -u DARKBLOOM_EXCLUSIVE_NATIVE_GPU_TEST \
    "$script_directory/run-nested-suite.sh" "$test_filter" --no-parallel || provider_test_status=$?
done
# This assertion observes the real allocator and must own its entire process,
# not merely run sequentially beside other tests in the same suite/process.
"$script_directory/run-exclusive-native-gpu-test.sh" \
  evaluatedPagesAvoidDoubleTaxAndRetainedAliasKeepsPressure || provider_test_status=$?
exit "$provider_test_status"
