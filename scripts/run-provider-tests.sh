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
# executed counts. Selection 1 also runs the MLX-free test targets in one
# parallel process; the last shard also runs the isolated processes below.
# Without a shard, everything runs here as one serial suite.
#
# PROVIDER_TEST_PROCESSES=P (default 1) makes job K of N run the P selections
# (K-1)*P+1 .. K*P of N*P at the same time, each serial in its own process with
# its own TMPDIR and provider state files. The isolated processes still run
# after all of them, alone.
provider_test_shard=${PROVIDER_TEST_SHARD:-}
provider_test_processes=${PROVIDER_TEST_PROCESSES:-1}
# Processes of one job read the same build; SwiftPM's lock on .build would
# otherwise serialize them. With --skip-build none of them writes the build.
lock_flag=()
# Report-only: in a sampled CI job (CI_RESOURCE_SAMPLES), tells
# scripts/ci-resource-sampler.py that selection $2 starts or ends ($1) under
# this shell (the mark's parent process), so its report names the selection of
# each large process.
mark_selection() {
  [ -z "${CI_RESOURCE_SAMPLES:-}" ] ||
    python3 "$script_directory/ci-resource-sampler.py" mark "$1" "$2" || true
}
run_provider_test_selection() {
  local selection=$1 name=${1//\//-of-} arguments argument parallel_flag=(--no-parallel) status attempt
  local selected=() report="$PROVIDER_TEST_REPORT_DIR/shard-$name"
  arguments=$(python3 "$script_directory/provider-test-shards.py" args "$selection" "$isolated_pattern") || return 1
  while IFS= read -r argument; do selected+=("$argument"); done <<<"$arguments"
  # The parallel class keeps Swift Testing's default in-process parallelism.
  [ "$selection" != parallel ] || parallel_flag=()
  echo "Provider test selection $name: ${#arguments} characters of filters"
  mark_selection start "$name"
  # Beside other processes, SwiftPM can find the build database locked by
  # another process's startup; it then runs the tests and exits 1. Such a
  # selection runs once more, but only when its log proves every test passed
  # (scripts/swift_test_lock_retry.py). The first attempt's log and xUnit
  # report stay beside the second's, as attempt-1-shard-<name>.*.
  for attempt in 1 2; do
    env -u MIMO_V26_SERIAL_NATIVE_TESTS -u DARKBLOOM_EXCLUSIVE_NATIVE_GPU_TEST -u DARKBLOOM_ISOLATED_DEADLINE_TEST \
      swift test --skip-build ${lock_flag[@]+"${lock_flag[@]}"} ${parallel_flag[@]+"${parallel_flag[@]}"} "${selected[@]}" \
      --xunit-output "$report.xml" 2>&1 | tee "$report.log"
    status=${PIPESTATUS[0]}
    if [ "$status" = 0 ] || [ "$attempt" = 2 ] || [ "$provider_test_processes" = 1 ] ||
        ! python3 "$script_directory/swift_test_lock_retry.py" "$report.log"; then
      break
    fi
    echo "Provider test selection $name: every test passed, but SwiftPM's build database was locked; running the selection once more"
    mv "$report.log" "$PROVIDER_TEST_REPORT_DIR/attempt-1-shard-$name.log"
    [ ! -f "$report.xml" ] || mv "$report.xml" "$PROVIDER_TEST_REPORT_DIR/attempt-1-shard-$name.xml"
  done
  mark_selection end "$name"
  python3 "$script_directory/provider-test-shards.py" counts "$selection" "$isolated_pattern" "$report.log" "$report.json" || status=1
  return "$status"
}
# One process slot: a selection, and after selection 1 the parallel class.
run_provider_test_slot() {
  local status=0
  run_provider_test_selection "$1" || status=$?
  if [[ "$1" == 1/* ]]; then
    run_provider_test_selection parallel || status=$?
  fi
  return "$status"
}
# A slot that runs beside others gets its own temporary directory and state
# files, in a subshell, so tests that write either never meet another
# process's files.
run_provider_test_slot_alone() (
  slot_root=$(mktemp -d "$provider_test_state_root/slot.XXXXXX") || exit 1
  mkdir -p "$slot_root/tmp" || exit 1
  export TMPDIR="$slot_root/tmp"
  export DARKBLOOM_STATE_FILE="$slot_root/daemon-state.json"
  export DARKBLOOM_LOADED_MODELS_FILE="$slot_root/loaded-models.json"
  export DARKBLOOM_VERIFIED_WEIGHTS_FILE="$slot_root/verified-weights.json"
  run_provider_test_slot "$1"
)
if [ -z "$provider_test_shard" ]; then
  env -u MIMO_V26_SERIAL_NATIVE_TESTS -u DARKBLOOM_EXCLUSIVE_NATIVE_GPU_TEST -u DARKBLOOM_ISOLATED_DEADLINE_TEST \
    swift test --skip-build --no-parallel --skip "$isolated_pattern" || provider_test_status=$?
else
  : "${PROVIDER_TEST_REPORT_DIR:?PROVIDER_TEST_SHARD needs PROVIDER_TEST_REPORT_DIR}"
  mkdir -p "$PROVIDER_TEST_REPORT_DIR" || exit 1
  # Read K and N before any other match replaces BASH_REMATCH.
  job="" jobs=""
  if [[ "$provider_test_shard" =~ ^([1-9][0-9]*)/([1-9][0-9]*)$ ]]; then
    job=${BASH_REMATCH[1]} jobs=${BASH_REMATCH[2]}
  fi
  if [ -z "$job" ] || (( job > jobs )) || ! [[ "$provider_test_processes" =~ ^[1-9]$ ]]; then
    echo "PROVIDER_TEST_SHARD must be K/N with 1 <= K <= N and PROVIDER_TEST_PROCESSES 1 to 9" >&2
    exit 2
  fi
  if [ "$provider_test_processes" = 1 ]; then
    run_provider_test_slot "$provider_test_shard" || provider_test_status=$?
  else
    lock_flag=(--ignore-lock)
    selections_total=$((jobs * provider_test_processes))
    pids=() names=()
    for ((slot = 1; slot <= provider_test_processes; slot++)); do
      selection="$(((job - 1) * provider_test_processes + slot))/$selections_total"
      name=${selection//\//-of-}
      names+=("$name")
      run_provider_test_slot_alone "$selection" > "$PROVIDER_TEST_REPORT_DIR/slot-$name.out" 2>&1 &
      pids+=("$!")
      # Start the processes apart, so their SwiftPM startups rarely meet on
      # the build database.
      (( slot == provider_test_processes )) || sleep "${PROVIDER_TEST_START_GAP:-15}"
    done
    for index in "${!pids[@]}"; do
      status=0
      wait "${pids[$index]}" || status=$?
      [ "$status" = 0 ] || provider_test_status=$status
      echo "::group::Provider test selection ${names[$index]} (exit $status)"
      cat "$PROVIDER_TEST_REPORT_DIR/slot-${names[$index]}.out"
      echo "::endgroup::"
    done
  fi
  # Only the last job (K == N) continues to the isolated processes.
  if [ "$job" != "$jobs" ]; then
    exit "$provider_test_status"
  fi
fi
for test_filter in "${isolated_filters[@]}"; do
  mark_selection start "$test_filter"
  if [ "$test_filter" = acceptedThenExpired ]; then
    env -u MIMO_V26_SERIAL_NATIVE_TESTS -u DARKBLOOM_EXCLUSIVE_NATIVE_GPU_TEST DARKBLOOM_ISOLATED_DEADLINE_TEST=1 \
      "$script_directory/run-nested-suite.sh" "$test_filter" --no-parallel || provider_test_status=$?
  else
    env -u MIMO_V26_SERIAL_NATIVE_TESTS -u DARKBLOOM_EXCLUSIVE_NATIVE_GPU_TEST -u DARKBLOOM_ISOLATED_DEADLINE_TEST \
      "$script_directory/run-nested-suite.sh" "$test_filter" --no-parallel || provider_test_status=$?
  fi
  mark_selection end "$test_filter"
done
# This assertion observes the real allocator and must own its entire process,
# not merely run sequentially beside other tests in the same suite/process.
exclusive_filter=evaluatedPagesAvoidDoubleTaxAndRetainedAliasKeepsPressure
mark_selection start "$exclusive_filter"
env -u MIMO_V26_SERIAL_NATIVE_TESTS -u DARKBLOOM_ISOLATED_DEADLINE_TEST "$script_directory/run-exclusive-native-gpu-test.sh" \
  "$exclusive_filter" || provider_test_status=$?
mark_selection end "$exclusive_filter"
exit "$provider_test_status"
