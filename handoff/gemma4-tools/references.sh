#!/bin/bash
# usage: references.sh BIN_DIR MODEL_DIR REQUEST_DIR OUT_DIR LABEL "REQUESTS" "CUT:RUNS CUT:RUNS"
# Single-Mac staged references. A refusal by the host memory gate is retried
# after a wait (twice at most) and counted; nothing is ever done to memory.
set -uo pipefail
. "$(dirname "$0")/env.sh"
bin="$1"; model="$2"; req="$3"; out="$4"; label="$5"; requests="$6"; plan="$7"
mkdir -p "$out"
gemma4_arithmetic
refusals=0; failures=0
for name in $requests; do
  for entry in $plan; do
    cut=${entry%%:*}; runs=${entry##*:}
    for run in $(seq 1 "$runs"); do
      report="$out/ref-$label-$name-cut$cut-run$run.json"
      [ -e "$report" ] && continue
      for attempt in 1 2 3; do
        "$bin/darkbloom-cluster-reference" --model-dir "$model" --request "$req/$name.json" --stage-cut "$cut" \
          --report "$report" --deadline-seconds 290 > "$report.stdout" 2> "$report.stderr"
        status=$?
        echo "$label $name cut=$cut run=$run attempt=$attempt exit=$status $(date -u +%H:%M:%SZ) $(tail -c 300 "$report.stderr" | tr '\n' ' ' | cut -c1-260)"
        if [[ $status == 0 ]]; then break; fi
        if grep -q -s -E "$GATE_REFUSAL" "$report.stderr" "$report.stdout"; then
          refusals=$((refusals + 1)); cp "$report.stderr" "$report.refusal-$attempt.stderr"
          [[ $attempt -lt 3 ]] && sleep 45
        else
          failures=$((failures + 1)); break
        fi
      done
    done
  done
done
pgrep -fl darkbloom-cluster-reference || echo "no reference process left"
echo "gate refusals: $refusals; other failures: $failures"
