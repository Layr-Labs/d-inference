# Shared by the Gemma 4 qualification scripts. Sourced, never run.
# No machine paths are written here: the task root is the first directory above
# these scripts that has tools/lane.sh, or GEMMA4_TASK_ROOT when that is set
# (the second Mac has no lane scripts, so it is set there). GEMMA4_MAC is "a"
# on the Mac that owns the lanes and "b" on the peer.
S="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -n "${GEMMA4_TASK_ROOT:-}" ]; then T="$GEMMA4_TASK_ROOT"; else
  T="$S"; while [ "$T" != / ] && [ ! -x "$T/tools/lane.sh" ]; do T="$(dirname "$T")"; done
fi
[ -d "$T/bin" ] || { echo "task root not found above $S; set GEMMA4_TASK_ROOT" >&2; exit 64; }
MAC="${GEMMA4_MAC:-a}"
B=$T/bin/gemma4
if [ "$MAC" = a ]; then
  W=$T/wt-gemma4                      # the worktree this directory is committed in
  G=$T/scratch/gemma4                 # model clones, product work directory, run scratch
  E=$T/evidence/gemma4-20261009
  APP=$T/scratch/night-bench/app-after/Darkbloom.app/Contents/MacOS/darkbloom
  METALLIB=$T/scratch/metallib-phase/mlx.metallib
  METALLIB_SHA256=fb1ba8f90b9f1cc346246b7240c3986771464bd977c67f0ef03186811f16c85c
else
  G=$T/gemma4
  E=$G/evidence
  APP=$T/night/app-after/Darkbloom.app/Contents/MacOS/darkbloom
fi
# The arithmetic the registered Gemma 4 contract requires of a process.
gemma4_arithmetic() {
  export DARKBLOOM_CBV2_ATTN_QUERY_BLOCK=128 DARKBLOOM_BF16_WEIGHTS=1 MLX_ENABLE_TF32=1
  export MLX_GEMMA4_FUSED_WEIGHTED_UNSORT=1 MLX_GATHER_QMM_EXPERT_SLICES=trust
}
# key -> catalog id
catalog_id() { case "$1" in qat4) echo gemma-4-26b-qat-4bit ;; g26) echo gemma-4-26b ;; g26x8) echo gemma-4-26b-8bit ;; *) return 1 ;; esac; }
local_model() { echo "$G/models/$(catalog_id "$1")"; }
# The peer, for the cross-cable step. tools/peer.env is the task's working
# context; what it names never reaches a log, because scrub removes it.
peer_setup() {
  . "$T/tools/peer.env"
  PEER=(ssh $PEER_CABLE_SSH_OPTS -o BatchMode=yes -o ConnectTimeout=10 "$PEER_CABLE_SSH")
  PEER_HOME=$("${PEER[@]}" 'printf %s "$HOME"') && [ -n "$PEER_HOME" ] || return 1
  PEER_HOST=$("${PEER[@]}" 'hostname -s') || return 1
  PEER_ROOT="$PEER_HOME/$PEER_DIR"; PEER_BIN="$PEER_ROOT/bin/gemma4"; PEER_G="$PEER_ROOT/gemma4"
  PEER_ENV="GEMMA4_TASK_ROOT=$PEER_ROOT GEMMA4_MAC=b"
}
peer_model() { echo "$PEER_G/models/$(catalog_id "$1")"; }
# Nothing that names a machine or its user reaches a log or a report.
scrub() {
  sed -E -e "s#$HOME#~#g" -e "s#/Users/[^/ \"']+#/Users/<user>#g" -e "s#$(hostname -s)#<mac-$MAC>#g" \
    -e "s#${PEER_HOST:-<no-peer-host>}#<mac-b>#g" -e "s#${PEER_CABLE_SSH:-<no-peer>}#<peer>#g" -e "s#$USER#<user>#g" \
    -e 's#([0-9]{1,3}\.){3}[0-9]{1,3}#<address>#g'
}
wired_bytes() { vm_stat | awk -v p="$(sysctl -n hw.pagesize)" '/Pages wired down/ { gsub("[.]", "", $4); printf "%.0f", $4 * p }'; }
vm_line() { vm_stat | awk -v p="$(sysctl -n hw.pagesize)" '/Pages free/ {gsub("[.]","",$3); f=$3*p} /File-backed pages/ {gsub("[.]","",$3); c=$3*p} /Pages wired down/ {gsub("[.]","",$4); w=$4*p} /Pages occupied by compressor/ {gsub("[.]","",$5); z=$5*p} END {printf "free %.1f GiB, file-backed %.1f GiB, wired %.1f GiB, compressor %.1f GiB", f/2^30, c/2^30, w/2^30, z/2^30}'; }
# What the host memory gate says when it refuses or stops a load. A match means:
# wait and try again later, count it, and do nothing to memory.
GATE_REFUSAL='actual free memory|actual-free or allocator|truly free|of admissible memory|more than this Mac.s|swap in use under memory pressure|pressured selected-stage|compressed or swapped|file cache'
compare() { # compare OUT REF CAND [extra flags]
  local out="$1" ref="$2" cand="$3"; shift 3
  "$B/darkbloom-cluster-pair-check" compare --reference "$ref" --candidate "$cand" "$@" > "$out" 2>&1
  echo "$(basename "$out"): $(grep -E '^verdict' "$out" | head -1) | $(grep -E '^tokens' "$out" | head -1 | cut -c1-110)"
}
