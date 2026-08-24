#!/bin/bash
# Run one decision-grade arrival-prefill cell on the dedicated M3 Max.
set -euo pipefail

label="${1:?usage: run_e2_cell.sh LABEL BATCH PROMPT CHUNK BUDGET [ITERATIONS]}"
batch="${2:?missing batch size}"
prompt="${3:?missing prompt tokens}"
chunk="${4:?missing prefill chunk (default or positive integer)}"
budget="${5:?missing step budget (default or positive integer)}"
iterations="${6:-2}"

case "$label" in
    *[!a-zA-Z0-9._-]* | "") echo "invalid label: $label" >&2; exit 2 ;;
esac
case "$batch" in 1 | 2 | 4) ;; *) echo "batch must be 1, 2, or 4" >&2; exit 2 ;; esac
for value in "$prompt" "$iterations"; do
    case "$value" in *[!0-9]* | 0 | "") echo "invalid positive integer: $value" >&2; exit 2 ;; esac
done
for value in "$chunk" "$budget"; do
    case "$value" in default) ;;
        *[!0-9]* | 0 | "") echo "invalid geometry: $value" >&2; exit 2 ;;
    esac
done
if [[ "$chunk" != default || "$budget" != default ]]; then
    echo "non-default CBv2 chunk/budget overrides were removed after E2; checkout the archived E2 experiment commit to reproduce that arm" >&2
    exit 2
fi

root="/Users/benchmark/work/qwen36-prefill"
binary="/Users/benchmark/work/d-inference/provider-swift/.build/release/darkbloom"
model="qwen3.6-35b-a3b-vl-mtp-mxfp8"
mkdir -p "$root/logs" "$root/results"
test -x "$binary"

meta="$root/logs/${label}.meta"
stderr="$root/logs/${label}.err"
json="$root/results/${label}.json"

{
    echo "ts_start=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    pmset -g batt
    pmset -g | awk '/powermode/'
    echo "binary_sha256=$(shasum -a 256 "$binary" | awk '{print $1}')"
    echo "batch=$batch"
    echo "prompt=$prompt"
    echo "chunk=$chunk"
    echo "budget=$budget"
    echo "iterations=$iterations"
} > "$meta"

environment=(
    env
    DARKBLOOM_ARRIVAL_TOLERANCE_MS=20
)

"${environment[@]}" "$binary" benchmark \
    --model "$model" \
    --arrival-invariance \
    --arrival-batch-size "$batch" \
    --arrival-prompt-tokens "$prompt" \
    --arrival-decode-tokens 2 \
    --arrival-iterations "$iterations" \
    --kv-backend contiguous \
    > "$json" 2> "$stderr"

{
    echo "exit=0"
    echo "ts_end=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    pmset -g batt
    pmset -g | awk '/powermode/'
} >> "$meta"

python3 - "$json" <<'PY'
import json
import sys

with open(sys.argv[1]) as handle:
    report = json.load(handle)
burst = next(pattern for pattern in report["patterns"] if pattern["name"] == "burst")
print({
    "schema": report["schemaVersion"],
    "batch": report["batchSize"],
    "prefill_tps": [
        round(sample["aggregatePrefillTokensPerSecond"], 1)
        for sample in burst["samples"]
    ],
    "median_prefill_tps": round(
        burst["medianAggregatePrefillTokensPerSecond"], 1
    ),
    "prefill_ms": [
        round(sample["prefillMakespanMs"], 1)
        for sample in burst["samples"]
    ],
    "checksums": [
        row["tokenChecksum"]
        for sample in burst["samples"]
        for row in sample["rows"]
    ],
})
PY
