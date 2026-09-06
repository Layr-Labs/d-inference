#!/usr/bin/env bash
# Run from provider-swift after building tests and staging the matched metallib.
# Allocator, controlled-interleaving and environment-mutation cases need isolation.
# Keep both outcomes: a failure in the general suite must not silence this gate.
set -uo pipefail
provider_test_status=0
isolated_filters=(
  ProcessMemoryNativeIntegrationTests
  processLedgerCannotCombineOldUsageWithNewMaterializationCredit
  defaultApplyProjectsSettings
)
isolated_pattern=$(IFS='|'; printf '%s' "${isolated_filters[*]}")
swift test --skip-build --skip "$isolated_pattern" || provider_test_status=$?
for test_filter in "${isolated_filters[@]}"; do
  ../scripts/run-nested-suite.sh "$test_filter" || provider_test_status=$?
done
exit "$provider_test_status"
