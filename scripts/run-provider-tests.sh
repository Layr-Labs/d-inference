#!/usr/bin/env bash
# Run from provider-swift after building tests and staging the matched metallib.
# Allocator, interleaving, environment, stage-deadline and URLSession mock
# cases need fresh processes. Every isolated suite still has a non-zero/no-skip gate.
# Keep both outcomes: a failure in the general suite must not silence this gate.
set -uo pipefail
script_directory=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# ProviderLoop tests can publish state without a per-loop override. Keep their
# snapshots away from the operator's running provider and recovery watchdog.
provider_test_state_root=$(mktemp -d "${TMPDIR:-/tmp}/darkbloom-provider-tests.XXXXXX") || exit 1
trap 'rm -rf "$provider_test_state_root"' EXIT
export DARKBLOOM_STATE_FILE="$provider_test_state_root/daemon-state.json"
export DARKBLOOM_LOADED_MODELS_FILE="$provider_test_state_root/loaded-models.json"
provider_test_status=0
isolated_filters=(
  emptyNativePoolTeardownUsesActualRetiredAdapter
  processLedgerCannotCombineOldUsageWithNewMaterializationCredit
  defaultApplyProjectsSettings
  stageDelta
  SpecDecHuggingFaceTests
  acceptedThenExpired
)
isolated_pattern=$(IFS='|'; printf '%s' "${isolated_filters[*]}")
isolated_pattern="ProcessMemoryNativeIntegrationTests|${isolated_pattern}"
# Swift Testing otherwise overlaps independent suites sharing process-wide MLX
# state and cooperative-executor capacity. Tests still create their own tasks
# and controlled interleavings; only unrelated test cases run sequentially.
# MiMo native fixtures have their own explicit, bounded CI selections.
env -u MIMO_V26_SERIAL_NATIVE_TESTS -u DARKBLOOM_EXCLUSIVE_NATIVE_GPU_TEST -u DARKBLOOM_ISOLATED_DEADLINE_TEST \
  swift test --skip-build --no-parallel --skip "$isolated_pattern" || provider_test_status=$?
for test_filter in "${isolated_filters[@]}"; do
  if [ "$test_filter" = acceptedThenExpired ]; then
    env -u MIMO_V26_SERIAL_NATIVE_TESTS -u DARKBLOOM_EXCLUSIVE_NATIVE_GPU_TEST DARKBLOOM_ISOLATED_DEADLINE_TEST=1 \
      "$script_directory/run-nested-suite.sh" "$test_filter" --no-parallel || provider_test_status=$?
  else
    env -u MIMO_V26_SERIAL_NATIVE_TESTS -u DARKBLOOM_EXCLUSIVE_NATIVE_GPU_TEST -u DARKBLOOM_ISOLATED_DEADLINE_TEST \
      "$script_directory/run-nested-suite.sh" "$test_filter" --no-parallel || provider_test_status=$?
  fi
done
# This assertion observes the real allocator and must own its entire process,
# not merely run sequentially beside other tests in the same suite/process.
env -u MIMO_V26_SERIAL_NATIVE_TESTS -u DARKBLOOM_ISOLATED_DEADLINE_TEST "$script_directory/run-exclusive-native-gpu-test.sh" \
  evaluatedPagesAvoidDoubleTaxAndRetainedAliasKeepsPressure || provider_test_status=$?
exit "$provider_test_status"
