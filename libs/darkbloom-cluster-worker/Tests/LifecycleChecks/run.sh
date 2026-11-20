#!/bin/bash
# The worker's request lifecycle tests (XCTest; CPU only, no model or GPU):
# WorkerTests and WorkerLaneTests, the worker coordinator over its real pipes
# with a fake runtime. Among them, D6's no-exit path: a running request whose
# rank's memory refused it ends alone (`aborted`, then `retired(aborted)`), the
# worker keeps its model and serves the next request, one request and lanes.
# CI runs them in Cluster Release Build Checks; nothing else runs this package's
# tests. DARKBLOOM_WORKER_TEST_SCRATCH reuses a retained build directory.
set -euo pipefail
task_package="$(cd "$(dirname "$0")/../.." && pwd)"
task_jobs="${DARKBLOOM_WORKER_TEST_JOBS:-4}"
[[ "$task_jobs" =~ ^[1-9][0-9]*$ ]] || { echo 'DARKBLOOM_WORKER_TEST_JOBS must be a positive integer' >&2; exit 2; }
swift test --package-path "$task_package" --jobs "$task_jobs" \
  ${DARKBLOOM_WORKER_TEST_SCRATCH:+--scratch-path "$DARKBLOOM_WORKER_TEST_SCRATCH"} \
  --filter 'DarkbloomClusterWorkerTests\.(WorkerTests|WorkerLaneTests)/'
