#!/bin/bash
# with_lane.sh -- run one heavy command under a shared "one heavy job" lane.
#
# usage: LANE=/abs/lane.sh with_lane.sh "<purpose>" <max-seconds> -- command [args...]
#
# The lane script must implement `acquire "<purpose>"` (exit 0 when taken, any
# other status when occupied) and `release`. This wrapper retries the acquire
# once a minute, runs the command, follows every process the command starts,
# and releases only after all of them have exited. A command that outlives
# <max-seconds> is asked to stop: SIGINT to every followed process, then
# SIGTERM 30 s later. Nothing is ever sent SIGKILL: a process that holds a
# loaded model must release it itself, so past that point the wrapper only
# waits and keeps the lane. Exit status: the command's own, or 75 when it was
# stopped at the limit (rerun to continue an incremental job).
#
# Limits: processes are found by polling the process table once a second, so a
# process that detaches by double-forking inside one interval is not followed;
# run servers in the foreground of the command. A command started this way has
# SIGINT ignored unless it installs its own handler, in which case SIGTERM is
# what stops it.
set -u
LANE="${LANE:?set LANE to the lane script}"
purpose="${1:?purpose}"; limit="${2:?max seconds}"; shift 2
[[ "${1:-}" == "--" ]] && shift
[[ $# -ge 1 ]] || { echo "with_lane: no command" >&2; exit 64; }
max_wait="${LANE_MAX_WAIT_SECONDS:-21600}"
waited=0
while true; do
  "$LANE" acquire "$purpose" >/dev/null; status=$?
  [[ $status -eq 0 ]] && break
  if (( waited >= max_wait )); then echo "with_lane: lane still occupied after ${waited}s" >&2; exit 73; fi
  sleep 60; waited=$((waited + 60))
done
echo "with_lane: acquired after ${waited}s at $(date -u +%H:%M:%SZ): $purpose" >&2
"$@" &
child=$!
known="$child"
# Keep the set of live processes descended from the command. A process whose
# parent has already exited stays in the set until it exits itself.
refresh() {
  known=$(ps -axo pid=,ppid= | awk -v seed="$known" '
    BEGIN { count = split(seed, items, " "); for (i = 1; i <= count; i++) want[items[i]] = 1 }
    { pid[NR] = $1; parent[NR] = $2; alive[$1] = 1 }
    END {
      changed = 1
      while (changed) {
        changed = 0
        for (i = 1; i <= NR; i++) if ((parent[i] in want) && !(pid[i] in want)) { want[pid[i]] = 1; changed = 1 }
      }
      out = ""; for (p in want) if (p in alive) out = out " " p
      print out
    }')
}
started=$SECONDS; stopped=0; stop_at=0
refresh
while [[ -n "${known// /}" ]]; do
  elapsed=$((SECONDS - started))
  if (( stopped == 0 && elapsed >= limit )); then
    echo "with_lane: limit ${limit}s reached; SIGINT to the command's processes" >&2
    kill -INT $known 2>/dev/null; stopped=1; stop_at=$SECONDS
  elif (( stopped == 1 && SECONDS - stop_at >= 30 )); then
    echo "with_lane: still running 30 s after SIGINT; SIGTERM (never SIGKILL)" >&2
    kill -TERM $known 2>/dev/null; stopped=2; stop_at=$SECONDS
  elif (( stopped == 2 && SECONDS - stop_at > 0 && (SECONDS - stop_at) % 60 == 0 )); then
    echo "with_lane: still alive $((SECONDS - stop_at))s after SIGTERM:$known; waiting, lane kept" >&2
  fi
  sleep 1
  refresh
done
wait "$child" 2>/dev/null; status=$?
"$LANE" release >/dev/null; release_status=$?
echo "with_lane: released (status $release_status) at $(date -u +%H:%M:%SZ) after $((SECONDS - started))s; command status $status" >&2
(( stopped > 0 )) && exit 75
exit $status
