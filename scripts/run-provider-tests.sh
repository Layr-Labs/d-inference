#!/usr/bin/env bash
# Run from provider-swift after building tests and staging the matched metallib.
# Allocator, interleaving, environment and stage-deadline cases need isolation.
# Keep both outcomes: a failure in the general suite must not silence this gate.
set -uo pipefail
provider_test_status=0
isolated_filters=(
  ProcessMemoryNativeIntegrationTests
  processLedgerCannotCombineOldUsageWithNewMaterializationCredit
  defaultApplyProjectsSettings
  stageDelta
)
isolated_pattern=$(IFS='|'; printf '%s' "${isolated_filters[*]}")
# Swift Testing otherwise overlaps independent suites sharing process-wide MLX
# state and cooperative-executor capacity. Tests still create their own tasks
# and controlled interleavings; only unrelated test cases run sequentially.
swift test --skip-build --no-parallel --skip "$isolated_pattern" || provider_test_status=$?
for test_filter in "${isolated_filters[@]}"; do
  ../scripts/run-nested-suite.sh "$test_filter" || provider_test_status=$?
done
exit "$provider_test_status"
