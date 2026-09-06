#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
PACKAGE_DIR="$REPO_ROOT/provider-swift"
LOG_DIR="${DARKBLOOM_TEST_LOG_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/darkbloom-provider-tests.XXXXXX")}"
mkdir -p "$LOG_DIR"

# Run after building tests and staging the source-matched metallib (make
# provider-test and CI do both). Imported GPU regressions latch MLX settings
# once per process; provider/CLI config tests intentionally mutate those keys.
# Both partitions remain required and use the same built test executable.
run_suite() {
  local name="$1"
  shift
  local log="$LOG_DIR/$name.log"
  # Explicit serialization applies to Swift Testing too (the CLI default only
  # describes XCTest). Race tests still create their own controlled concurrency.
  swift test --package-path "$PACKAGE_DIR" --skip-build --no-parallel "$@" 2>&1 | tee "$log"
  # A routed-away executable test target can exit successfully with no Swift
  # Testing cases. Do not accept that as a passing partition.
  if ! grep -Eq 'Test run with [1-9][0-9]* tests?( in [0-9]+ suites?)? passed' "$log"; then
    printf 'No passing Swift Testing execution count for %s; inspect %s\n' "$name" "$log" >&2
    exit 1
  fi
}

run_suite provider --skip GPTOSSOptimizationTests
run_suite gpu-regressions --filter GPTOSSOptimizationTests
printf 'Both provider test partitions passed. Logs: %s\n' "$LOG_DIR"
