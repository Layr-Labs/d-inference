#!/bin/bash
# usage: abcd.sh KEY CUT        (SKIP_ABC=yes: only D, the oracle must exist)
# Run it under tools/lane.sh (through with-lane.sh). A, B and C on this Mac;
# when C has passed, tools/lane-b.sh is taken as well (the ordered second lane),
# the binaries are put on the second Mac if they are not the current ones, and D
# runs on the pair. If lane-b.sh stays busy this hold ends after C and D has to
# be queued again with SKIP_ABC=yes.
set -uo pipefail
. "$(dirname "$0")/env.sh"
key="$1"; cut="$2"
[ "${SKIP_ABC:-no}" = yes ] || "$S/abc.sh" "$key" "$cut" || { echo "A, B, C did not all pass on Mac A (status $?): D not started"; exit 1; }
held_b=no; trap '[ $held_b = yes ] && "$T/tools/lane-b.sh" release >/dev/null 2>&1' EXIT
tries=0
until "$T/tools/lane-b.sh" acquire "gemma4: D on the pair ($key, cut $cut), about 10 min" >/dev/null 2>&1; do
  tries=$((tries + 1))
  [ $tries -gt "${LANE_B_TRIES:-8}" ] && { echo "lane-b.sh still busy after $tries tries at $(date -u +%H:%M:%SZ): D not started in this hold"; exit 20; }
  sleep 40
done
held_b=yes; echo "lane-b.sh held at $(date -u +%H:%M:%SZ)"
"$S/stage-peer.sh" && "$S/ladder-d.sh" "$key" "$cut"; rc=$?
"$T/tools/lane-b.sh" release >/dev/null 2>&1; held_b=no; echo "lane-b.sh released at $(date -u +%H:%M:%SZ)"
exit $rc
