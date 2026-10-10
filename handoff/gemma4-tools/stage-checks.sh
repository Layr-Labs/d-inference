#!/bin/bash
# usage: stage-checks.sh BIN_DIR MODEL_DIR OUT_DIR LABEL CUT...
# One rank's verified stage load and release per (cut, rank). A refusal by the
# host memory gate is retried after a wait, at most twice, and counted; nothing
# is ever done to memory.
set -uo pipefail
. "$(dirname "$0")/env.sh"
bin="$1"; model="$2"; out="$3"; label="$4"; shift 4
mkdir -p "$out"
gemma4_arithmetic
refusals=0; failures=0
for cut in "$@"; do
  for rank in 0 1; do
    name="$out/stage-$label-cut$cut-rank$rank"
    for attempt in 1 2 3; do
      vm_stat > "$name.vmstat-before.txt"
      "$bin/darkbloom-cluster-stage-check" --model-dir "$model" --rank "$rank" --stage-cut "$cut" \
        --deadline-seconds 240 > "$name.json" 2> "$name.stderr"
      status=$?
      vm_stat > "$name.vmstat-after.txt"
      echo "$label cut=$cut rank=$rank attempt=$attempt exit=$status $(date -u +%H:%M:%SZ)"
      if [[ $status == 0 ]]; then break; fi
      if grep -q -s -E "$GATE_REFUSAL" "$name.stderr" "$name.json"; then
        refusals=$((refusals + 1)); cp "$name.stderr" "$name.refusal-$attempt.stderr"; cp "$name.json" "$name.refusal-$attempt.json" 2>/dev/null
        [[ $attempt -lt 3 ]] && sleep 45
      else
        failures=$((failures + 1)); break
      fi
    done
  done
done
pgrep -fl darkbloom-cluster-stage-check || echo "no stage-check process left"
echo "gate refusals: $refusals; other failures: $failures"
