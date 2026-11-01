#!/bin/bash
# The four native worker products, then the script checks that need no model,
# then the test bundles. Compile only, at most 8 jobs: run it under
# tools/lane-build.sh (through with-lane.sh).
set -uo pipefail
. "$(dirname "$0")/env.sh"
export PATH=$T/tools/native-swift:$PATH DARKBLOOM_CLUSTER_WORKER_BUILD_JOBS=8
status=0
for product in darkbloom-cluster-stage-check darkbloom-cluster-reference darkbloom-cluster-worker darkbloom-cluster-pair-check; do
  echo "== $product $(date -u +%H:%M:%SZ)"
  if ! bash $W/libs/darkbloom-cluster-worker/build-native-worker.sh $W/libs/darkbloom-cluster-worker "$product" "$METALLIB" "$METALLIB_SHA256" 2>&1 | scrub; then
    echo "BUILD FAILED: $product"; status=1
  fi
  [ "${PIPESTATUS[0]}" = 0 ] || { echo "BUILD FAILED: $product"; status=1; }
done
if [[ $status == 0 ]]; then
  for check in libs/darkbloom-cluster-worker/Tests/CapabilityChecks/run.sh libs/darkbloom-cluster/Tests/PrefillScheduleChecks/run.sh \
               libs/darkbloom-cluster/Tests/CapabilityChecks/run.sh libs/darkbloom-cluster/Tests/StageTransferChecks/run.sh \
               libs/darkbloom-cluster/Tests/CheckpointChecks/run.sh; do
    echo "== $check $(date -u +%H:%M:%SZ)"
    if bash "$W/$check" 2>&1 | scrub; [ "${PIPESTATUS[0]}" = 0 ]; then echo "CHECK PASSED: $check"; else echo "CHECK FAILED: $check"; status=1; fi
  done
fi
echo "== libs/darkbloom-cluster/Tests/StageMetadataChecks/run.py $(date -u +%H:%M:%SZ)"
rm -rf $G/run/stage-metadata-checks; mkdir -p $G/run
if python3 $W/libs/darkbloom-cluster/Tests/StageMetadataChecks/run.py --output $G/run/stage-metadata-checks > $G/run/stage-metadata-checks.log 2>&1; then echo "CHECK PASSED: StageMetadataChecks"; else echo "CHECK FAILED: StageMetadataChecks"; status=1; fi
echo "products-exit=$status $(date -u +%H:%M:%SZ)"
[ $status = 0 ] && "$S/build-tests.sh"
exit $status
