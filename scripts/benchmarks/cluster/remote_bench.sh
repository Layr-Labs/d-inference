#!/bin/bash
# remote_bench.sh -- run serve_bench.py on a second Mac over SSH and wait for it.
#
# usage: PEER_SSH=user@host [PEER_SSH_OPTIONS="-o Key=Value ..."] \
#        remote_bench.sh <remote-dir> <remote-out-subdir> <local-out-dir> <name> -- <serve_bench.py arguments>
#
# <remote-dir> is relative to the remote home and must hold
# src/scripts/benchmarks/cluster/serve_bench.py (the same tree layout as the
# repository). Paths in the serve_bench arguments are relative to <remote-dir>.
#
# The job is started detached on the second Mac (nohup, its own log and exit
# file), so a dropped SSH connection neither stops it nor makes this script
# return early: this script polls until the remote process is gone, then copies
# <remote-dir>/<remote-out-subdir>/ back. On SIGINT or SIGTERM it asks the
# remote job to stop (SIGTERM, which makes serve_bench.py stop its server
# gracefully) and keeps waiting. Process patterns are written with a bracket
# (serve_bench[.]py) so that the remote shell running the check does not match
# its own command line. Nothing is ever sent SIGKILL. The destination
# comes from the environment so that no address is written into a file.
set -u
: "${PEER_SSH:?set PEER_SSH to the SSH destination}"
remote_dir="${1:?remote dir}"; remote_out="${2:?remote out subdir}"; local_out="${3:?local out dir}"; name="${4:?name}"
shift 4; [[ "${1:-}" == "--" ]] && shift
options=(-o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=4)
# shellcheck disable=SC2206
extra=(${PEER_SSH_OPTIONS:-})
rssh() { ssh "${options[@]}" "${extra[@]}" "$PEER_SSH" "$@"; }
arguments=$(printf '%q ' "$@")
start="cd $(printf '%q' "$remote_dir") && mkdir -p $(printf '%q' "$remote_out") && rm -f $(printf '%q' "$remote_out/$name.exit") && (nohup sh -c 'python3 src/scripts/benchmarks/cluster/serve_bench.py $arguments; echo \$? > $(printf '%q' "$remote_out/$name.exit")' > $(printf '%q' "$remote_out/$name.run.log") 2>&1 < /dev/null & echo \$!)"
pid=$(rssh "$start") || { echo "remote_bench: could not start the remote job" >&2; exit 70; }
[[ "$pid" =~ ^[0-9]+$ ]] || { echo "remote_bench: unexpected start output: $pid" >&2; exit 70; }
echo "remote_bench: remote job $pid started at $(date -u +%H:%M:%SZ)" >&2
asked=0
trap 'asked=1' INT TERM
unknown=0
while true; do
  if (( asked == 1 )); then
    echo "remote_bench: asking the remote job to stop (SIGTERM)" >&2
    rssh "pkill -TERM -f 'cluster/serve_bench[.]py' || true" && asked=2
  fi
  state=$(rssh "if kill -0 $pid 2>/dev/null || pgrep -f 'cluster/serve_bench[.]py' >/dev/null; then echo running; else echo gone; fi" 2>/dev/null) || state=unknown
  case "$state" in
    gone) break ;;
    unknown) unknown=$((unknown + 1)); (( unknown % 6 == 0 )) && echo "remote_bench: cannot reach the second Mac (${unknown} tries); still waiting" >&2 ;;
    *) unknown=0 ;;
  esac
  sleep 10 &
  wait $! 2>/dev/null
done
status=$(rssh "cat $(printf '%q' "$remote_dir/$remote_out/$name.exit") 2>/dev/null" || true)
left=$(rssh "pgrep -fl '$remote_dir/bin/darkbloom[ ]start' | wc -l" 2>/dev/null | tr -d ' ')
mkdir -p "$local_out"
rsync -a -e "ssh ${options[*]} ${extra[*]}" "$PEER_SSH:$remote_dir/$remote_out/" "$local_out/" || echo "remote_bench: copying results back failed" >&2
echo "remote_bench: remote job ended with status ${status:-unknown}; provider processes left on the second Mac: ${left:-unknown}; finished $(date -u +%H:%M:%SZ)" >&2
[[ "${left:-1}" == "0" ]] || exit 71
exit "${status:-70}"
