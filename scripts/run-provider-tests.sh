#!/usr/bin/env bash
# Run from provider-swift after building tests and staging the matched metallib.
# Keep failures visible while every process-sensitive case still gets its run.
set -uo pipefail
provider_test_status=0
isolated_filters=(
  defaultApplyProjectsSettings
  stageDelta
)
isolated_pattern=$(IFS='|'; printf '%s' "${isolated_filters[*]}")
# Unrelated Swift Testing cases otherwise share process-wide MLX state and
# executor capacity. Tests retain their own tasks and controlled interleavings.
swift test --skip-build --no-parallel --skip "$isolated_pattern" || provider_test_status=$?
for test_filter in "${isolated_filters[@]}"; do
  ../scripts/run-nested-suite.sh "$test_filter" || provider_test_status=$?
done
exit "$provider_test_status"
