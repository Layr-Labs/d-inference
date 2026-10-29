#!/usr/bin/env bash
# Run from provider-swift after building tests and staging the matched metallib.
# Allocator, compiled-device, interleaving, environment, stage-deadline and URLSession mock
# cases need fresh processes. Every isolated suite still has a non-zero/no-skip gate.
# Keep both outcomes: a failure in the general suite must not silence this gate.
set -uo pipefail
script_directory=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# Coverage runs set PROVIDER_COVERAGE_DIR after an instrumented build
# (`swift build --build-tests --enable-code-coverage`). Each test process then
# writes its own profile there. `swift test --enable-code-coverage` is not used:
# it deletes earlier profiles and replaces LLVM_PROFILE_FILE on every call.
if [[ -n "${PROVIDER_COVERAGE_DIR:-}" ]]; then
  mkdir -p "$PROVIDER_COVERAGE_DIR"
  export LLVM_PROFILE_FILE="$PROVIDER_COVERAGE_DIR/%p-%m.profraw"
fi
# ProviderLoop tests can publish state without a per-loop override. Keep their
# snapshots away from the operator's running provider and recovery watchdog.
provider_test_state_root=$(mktemp -d "${TMPDIR:-/tmp}/darkbloom-provider-tests.XXXXXX") || exit 1
trap 'rm -rf "$provider_test_state_root"' EXIT
export DARKBLOOM_STATE_FILE="$provider_test_state_root/daemon-state.json"
export DARKBLOOM_LOADED_MODELS_FILE="$provider_test_state_root/loaded-models.json"
export DARKBLOOM_VERIFIED_WEIGHTS_FILE="$provider_test_state_root/verified-weights.json"
provider_test_status=0
isolated_filters=(
  SSDShorterNativeBlockRestoreTests
  SSDNativeCheckpointOracleTests
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
# CI sets PROVIDER_TEST_SHARD=K/N (scripts/provider-test-shards.py chooses the
# suites) and PROVIDER_TEST_REPORT_DIR for each run's log, xUnit report and
# executed counts. Shard 1 also runs the MLX-free test targets in one parallel
# process; the last shard also runs the isolated processes below. Without a
# shard, everything runs here as one serial suite.
provider_test_shard=${PROVIDER_TEST_SHARD:-}
run_provider_test_selection() {
  local selection=$1 name=${1//\//-of-} arguments parallel_flag=(--no-parallel) status
  local selected=() report="$PROVIDER_TEST_REPORT_DIR/shard-${1//\//-of-}"
  arguments=$(python3 "$script_directory/provider-test-shards.py" args "$selection" "$isolated_pattern") || return 1
  while IFS= read -r argument; do selected+=("$argument"); done <<<"$arguments"
  # The parallel class keeps Swift Testing's default in-process parallelism.
  [ "$selection" != parallel ] || parallel_flag=()
  echo "Provider test selection $name: ${#arguments} characters of filters"
  env -u MIMO_V26_SERIAL_NATIVE_TESTS -u DARKBLOOM_EXCLUSIVE_NATIVE_GPU_TEST -u DARKBLOOM_ISOLATED_DEADLINE_TEST \
    swift test --skip-build ${parallel_flag[@]+"${parallel_flag[@]}"} "${selected[@]}" \
    --xunit-output "$report.xml" 2>&1 | tee "$report.log"
  status=${PIPESTATUS[0]}
  python3 "$script_directory/provider-test-shards.py" counts "$selection" "$isolated_pattern" "$report.log" "$report.json" || status=1
  return "$status"
}
if [ -z "$provider_test_shard" ]; then
  env -u MIMO_V26_SERIAL_NATIVE_TESTS -u DARKBLOOM_EXCLUSIVE_NATIVE_GPU_TEST -u DARKBLOOM_ISOLATED_DEADLINE_TEST \
    swift test --skip-build --no-parallel --skip "$isolated_pattern" || provider_test_status=$?
else
  : "${PROVIDER_TEST_REPORT_DIR:?PROVIDER_TEST_SHARD needs PROVIDER_TEST_REPORT_DIR}"
  mkdir -p "$PROVIDER_TEST_REPORT_DIR" || exit 1
  run_provider_test_selection "$provider_test_shard" || provider_test_status=$?
  if [[ "$provider_test_shard" == 1/* ]]; then
    run_provider_test_selection parallel || provider_test_status=$?
  fi
  # Only the last shard (K == N) continues to the isolated processes.
  if [ "${provider_test_shard%/*}" != "${provider_test_shard#*/}" ]; then
    exit "$provider_test_status"
  fi
fi
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
