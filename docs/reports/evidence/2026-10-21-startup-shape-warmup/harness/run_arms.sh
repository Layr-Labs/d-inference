#!/bin/bash
# First-~8K-request TTFT after process start on the M3 Ultra, warmup off vs on, cold vs warm per-app
# Metal shader cache. Arms in $5 run in the given order:
#   A cold (fresh id), warmup off      B cold (fresh id), warmup on
#   C warm (B's id), warmup off        D warm (B's id), warmup on
# Usage: run_arms.sh <model> <target-tokens> <bin-dir> <tag> <arms> [bundle-stamp]
set -u
W=/Users/gaj/ttft-bench/agents/warmup
m="$1"; L="$2"; SRC="$3"; tag="$4"; ARMS="$5"; STAMP="${6:-$(date +%s)}"
OUT=$W/out/$tag; mkdir -p "$OUT"
CACHE=$(getconf DARWIN_USER_CACHE_DIR)
short=$(echo "$m" | tr -cd 'a-zA-Z0-9' | cut -c1-12)
IDA=io.darkbloom.ttftw4.$tag.$short.off.$STAMP
IDB=io.darkbloom.ttftw4.$tag.$short.on.$STAMP
PLAN="$L,$L,$L"
run() { # arm id warmup(on|off)
  local arm=$1 id=$2 w=$3 bin
  bin=$($W/make_bundle.sh "$SRC" "$id" "$W/bundles")
  echo "=== $(date +%T) $m arm $arm bundle=$id warmup=$w cache_dir_before=$([ -d "$CACHE/$id" ] && echo yes || echo no) thermal=$(/Users/gaj/ttft-bench/tools/thermal | awk '{print $1}') load=$(sysctl -n vm.loadavg | awk '{print $2}')"
  if [ "$w" = on ]; then
    env -u DARKBLOOM_TTFT_SHAPE_WARMUP $W/session.sh "$bin" "$m" "$OUT" "$m-$arm" "$PLAN"
  else
    DARKBLOOM_TTFT_SHAPE_WARMUP=0 $W/session.sh "$bin" "$m" "$OUT" "$m-$arm" "$PLAN"
  fi
  echo "[$arm] cache_dir_after=$(du -sh "$CACHE/$id" 2>/dev/null | cut -f1)"
}
for (( i=0; i<${#ARMS}; i++ )); do
  case "${ARMS:$i:1}" in
    A) run A "$IDA" off;; B) run B "$IDB" on;; C) run C "$IDB" off;; D) run D "$IDB" on;;
  esac
done
echo "=== $(date +%T) done $m $tag"
