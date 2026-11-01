#!/bin/bash
# usage: with-lane.sh LANE_SCRIPT "purpose" TIMEOUT_SECONDS command...
# Waits first come, first served (retry every 40 s), runs one batch, releases.
set -uo pipefail
lane="$1"; purpose="$2"; limit="$3"; shift 3
start=$(date +%s); tries=0
while true; do
  if out=$("$lane" acquire "$purpose" 2>&1); then break; fi
  tries=$((tries + 1))
  if (( $(date +%s) - start > limit )); then echo "lane wait exceeded ${limit}s after $tries retries: $out"; exit 75; fi
  sleep 40
done
echo "lane acquired after $(( $(date +%s) - start )) s, $tries retries"
"$@"; status=$?
"$lane" release
exit $status
