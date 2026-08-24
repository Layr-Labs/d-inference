#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TELEMETRY_DIR="$SCRIPT_DIR/../mpp-throughput"
OUT_DIR="${1:-$SCRIPT_DIR/profile-out}"
BINARY="${DARKBLOOM_BENCH_BINARY:-/Users/gaj/work/d-inference/provider-swift/.build/release/darkbloom}"
MODEL="${DARKBLOOM_BENCH_MODEL:-qwen3.6-35b-a3b-vl-mtp-mxfp8}"
PROMPT_TOKENS="${DARKBLOOM_PREFILL_PROFILE_TOKENS:-8192}"
ITERATIONS="${DARKBLOOM_PREFILL_PROFILE_ITERATIONS:-3}"
TRACE_WINDOW="${DARKBLOOM_PREFILL_TRACE_WINDOW:-20s}"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/qwen-prefill-physical.XXXXXX")"
SAMPLER_PID=""
STOP_FILE=""

cleanup() {
    if [[ -n "$SAMPLER_PID" ]] && kill -0 "$SAMPLER_PID" 2>/dev/null; then
        : >"$STOP_FILE"
        wait "$SAMPLER_PID" 2>/dev/null || true
    fi
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

for value in "$PROMPT_TOKENS" "$ITERATIONS"; do
    case "$value" in
        *[!0-9]* | 0 | "")
            echo "fatal: prompt tokens and iterations must be positive integers" >&2
            exit 2
            ;;
    esac
done
if [[ -e "$OUT_DIR" ]]; then
    echo "fatal: output already exists: $OUT_DIR" >&2
    exit 2
fi
if [[ ! -x "$BINARY" ]]; then
    echo "fatal: benchmark binary is not executable: $BINARY" >&2
    exit 2
fi
if [[ ! -f "$TELEMETRY_DIR/agx_metrics.py" ||
      ! -f "$TELEMETRY_DIR/summarize_physical.py" ]]
then
    echo "fatal: physical telemetry helpers are missing" >&2
    exit 2
fi
mkdir -p "$OUT_DIR"

STRICT_ENV_KEYS=(
    DARKBLOOM_QWEN35_PREFILL_ARTIFACT_ONLY
    DARKBLOOM_QWEN35_PREFILL_FULL_LAYERS
    DARKBLOOM_QWEN35_PREFILL_MOE_TOP_K
    DARKBLOOM_QWEN35_PREFILL_MOE_FULL_LAYERS
    DARKBLOOM_QWEN35_PREFILL_PROFILE
    DARKBLOOM_QWEN35_PREFILL_DRAFT_PROFILE
    DARKBLOOM_QWEN35_PREFILL_CORRECTION_FRACTION
    DARKBLOOM_QWEN35_PREFILL_CORRECTION_POLICY
    DARKBLOOM_CBV2_PREFILL_CHUNK
    DARKBLOOM_CBV2_MAX_BATCHED_TOKENS
    DARKBLOOM_CBV2_SOLO_PREFILL_STRIPE
    DARKBLOOM_CBV2_MAX_PARTIAL_PREFILLS
    DARKBLOOM_CBV2_MIXED_PREFILL_CAP
    DARKBLOOM_CBV2_PREFILL_NARROWING
    DARKBLOOM_QUALITY_CANONICAL_EXACT_PREFILL
    DARKBLOOM_PREFIX_BENCH_CACHE_MAX_BYTES
)
unset "${STRICT_ENV_KEYS[@]}"
export DARKBLOOM_ARRIVAL_TOLERANCE_MS=20

power_source() {
    pmset -g batt | sed -n '1p'
}

ac_power_mode() {
    pmset -g custom | awk '
        /^AC Power:/ { in_ac=1; next }
        /^[A-Za-z].*Power:/ { in_ac=0 }
        in_ac && $1 == "powermode" { print $2; exit }
    '
}

power_gate_passes() {
    [[ "$(power_source)" == *"AC Power"* && "$(ac_power_mode)" == "2" ]]
}

capture_power() {
    echo "DATE_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "POWER_SOURCE=$(power_source)"
    echo "POWER_MODE_AC=$(ac_power_mode)"
    echo "PMSET_THERM_BEGIN"
    pmset -g therm
    echo "PMSET_THERM_END"
    echo "PMSET_BATT_BEGIN"
    pmset -g batt
    echo "PMSET_BATT_END"
}

capture_processes() {
    ps -axo pid,pcpu,pmem,command \
        | sort -k2 -nr \
        | sed -n '1,35p' \
        | sed 's/[[:space:]]*$//'
}

competing_workload() {
    local name
    for name in darkbloom swift-build swift-driver swift-frontend xctrace; do
        if pgrep -x "$name" >/dev/null; then
            return 0
        fi
    done
    return 1
}

record_header() {
    echo "PROBE=qwen-cold-strict-prefill-physical-profile"
    echo "DATE_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "HOST=$(scutil --get ComputerName)"
    echo "HW_MODEL=$(sysctl -n hw.model)"
    echo "OS=$(sw_vers -productVersion)"
    echo "OS_BUILD=$(sw_vers -buildVersion)"
    echo "XCODE=$(xcodebuild -version | tr '\n' ';')"
    echo "SWIFT=$(swift --version | tr '\n' ';')"
    echo "POWER_SOURCE=$(power_source)"
    echo "POWER_MODE_AC=$(ac_power_mode)"
    echo "MODEL=$MODEL"
    echo "PROMPT_TOKENS_PER_REQUEST=$PROMPT_TOKENS"
    echo "ITERATIONS=$ITERATIONS"
    echo "BATCHES=1,2,4"
    echo "KV_BACKEND=contiguous"
    echo "PREFIX_CACHE=off"
    echo "NUMERICAL_POSTURE=strict-default-top8"
    echo "TRACE_WINDOW=$TRACE_WINDOW"
    echo "BINARY=$BINARY"
    echo "BINARY_SHA256=$(shasum -a 256 "$BINARY" | awk '{print $1}')"
    if [[ -e "$(dirname "$BINARY")/mlx.metallib" ]]; then
        echo "METALLIB_SHA256=$(shasum -a 256 \
            "$(dirname "$BINARY")/mlx.metallib" | awk '{print $1}')"
    else
        echo "METALLIB_SHA256=unavailable"
    fi
    echo "SOURCE_SHA256=$(shasum -a 256 \
        "$SCRIPT_DIR/run.sh" \
        "$SCRIPT_DIR/counter_access.swift" \
        "$SCRIPT_DIR/summarize_prefill.py" \
        "$TELEMETRY_DIR/agx_metrics.py" \
        "$TELEMETRY_DIR/summarize_physical.py" \
        | tr '\n' ';')"
    for key in "${STRICT_ENV_KEYS[@]}"; do
        echo "EXECUTION_ENV key=$key value=unset"
    done
    echo "EXECUTION_ENV key=DARKBLOOM_ARRIVAL_TOLERANCE_MS value=20"
}

if [[ "$(sysctl -n hw.model)" != "Mac15,9" ]]; then
    echo "fatal: physical profile requires Mac15,9" >&2
    exit 2
fi
if ! power_gate_passes; then
    echo "fatal: physical profile requires AC High Power" >&2
    exit 2
fi
if competing_workload; then
    echo "fatal: competing benchmark/build/tracer process is active" >&2
    exit 2
fi

capture_power >"$OUT_DIR/power-before.txt"
capture_processes >"$OUT_DIR/processes-before.txt"
system_profiler SPDisplaysDataType >"$OUT_DIR/gpu-metadata.txt"
python3 "$TELEMETRY_DIR/agx_metrics.py" inventory >"$OUT_DIR/agx-inventory.txt"

xcrun swiftc -O -framework Metal \
    "$SCRIPT_DIR/counter_access.swift" \
    -o "$WORK_DIR/counter-access" \
    >"$OUT_DIR/counter-compiler.txt" 2>&1
"$WORK_DIR/counter-access" >"$OUT_DIR/counter-access.txt"

set +e
/usr/bin/powermetrics --samplers gpu_power -i 100 -n 1 \
    >"$OUT_DIR/powermetrics-access.txt" 2>&1
POWERMETRICS_STATUS=$?
xcrun xctrace record \
    --template "Power Profiler" \
    --no-prompt \
    --output "$WORK_DIR/power-profiler-access.trace" \
    --launch -- /bin/sleep 0.1 \
    >"$OUT_DIR/power-profiler-access.txt" 2>&1
POWER_PROFILER_STATUS=$?
set -e

TRACE_SCHEMAS=(
    device-thermal-state-intervals
    gpu-performance-device-state-intervals
    gpu-performance-state-info
    gpu-performance-state-intervals
    metal-gpu-state-intervals
    metal-gpu-intervals
    metal-application-command-buffer-submissions
    metal-kernel-resource-allocations
    graphics-compiler-spill-events
    gpu-counter-info
)

for batch in 1 2 4; do
    cell="$OUT_DIR/b$batch"
    mkdir -p "$cell/trace-export"
    if ! power_gate_passes; then
        echo "fatal: power posture changed before B$batch" >&2
        exit 1
    fi
    if competing_workload; then
        echo "fatal: competing workload appeared before B$batch" >&2
        exit 1
    fi
    capture_power >"$cell/power-before.txt"
    capture_processes >"$cell/processes-before.txt"
    python3 "$TELEMETRY_DIR/agx_metrics.py" once --phase before \
        >"$cell/agx-samples.jsonl"

    STOP_FILE="$WORK_DIR/stop-b$batch"
    phase_file="$WORK_DIR/phase-b$batch"
    printf 'during\n' >"$phase_file"
    python3 "$TELEMETRY_DIR/agx_metrics.py" loop \
        --phase-file "$phase_file" \
        --stop-file "$STOP_FILE" \
        --interval 1 \
        >>"$cell/agx-samples.jsonl" \
        2>"$cell/agx-sampler-errors.txt" &
    SAMPLER_PID=$!

    trace="$cell/cold-strict-b$batch.trace"
    set +e
    xcrun xctrace record \
        --template "Metal System Trace" \
        --window "$TRACE_WINDOW" \
        --no-prompt \
        --output "$trace" \
        --target-stdout "$cell/report.json" \
        --launch -- \
        "$BINARY" benchmark \
        --model "$MODEL" \
        --arrival-invariance \
        --arrival-batch-size "$batch" \
        --arrival-prompt-tokens "$PROMPT_TOKENS" \
        --arrival-decode-tokens 2 \
        --arrival-iterations "$ITERATIONS" \
        --kv-backend contiguous \
        >"$cell/xctrace-record.txt" 2>&1
    record_status=$?
    set -e

    printf 'after\n' >"$phase_file"
    python3 "$TELEMETRY_DIR/agx_metrics.py" once --phase after \
        >>"$cell/agx-samples.jsonl"
    : >"$STOP_FILE"
    wait "$SAMPLER_PID"
    SAMPLER_PID=""
    capture_power >"$cell/power-after.txt"
    capture_processes >"$cell/processes-after.txt"

    if [[ "$record_status" -ne 0 ]]; then
        echo "fatal: xctrace/benchmark failed for B$batch" >&2
        exit 1
    fi
    xcrun xctrace export \
        --input "$trace" \
        --toc \
        --output "$cell/trace-toc.xml" \
        >"$cell/xctrace-export-toc.txt" 2>&1
    for schema_name in "${TRACE_SCHEMAS[@]}"; do
        xcrun xctrace export \
            --input "$trace" \
            --xpath \
            "/trace-toc/run[@number=\"1\"]/data/table[@schema=\"$schema_name\"]" \
            --output "$cell/trace-export/$schema_name.xml" \
            >"$cell/trace-export/$schema_name.stderr.txt" 2>&1
    done
    python3 "$SCRIPT_DIR/summarize_prefill.py" "$cell/report.json" \
        >"$cell/prefill-summary.txt"
    python3 "$TELEMETRY_DIR/summarize_physical.py" \
        --agx-jsonl "$cell/agx-samples.jsonl" \
        --trace-directory "$cell/trace-export" \
        --perf-inventory "$OUT_DIR/agx-inventory.txt" \
        >"$cell/physical-summary.txt" \
        2>"$cell/physical-summary-errors.txt"
    du -sk "$trace" | awk '{print $1}' >"$cell/trace-size-kib.txt"
    (
        cd "$cell/trace-export"
        shasum -a 256 ./*.xml
    ) >"$cell/trace-export-sha256.txt"
done

capture_power >"$OUT_DIR/power-after.txt"
capture_processes >"$OUT_DIR/processes-after.txt"
if ! power_gate_passes; then
    echo "fatal: power posture changed after matrix" >&2
    exit 1
fi

{
    record_header
    echo "RUN_VALID=yes"
    echo "POWERMETRICS_UNPRIVILEGED_EXIT=$POWERMETRICS_STATUS"
    echo "POWER_PROFILER_MACOS_EXIT=$POWER_PROFILER_STATUS"
    echo "GPU_POWER_OBSERVABILITY=unavailable"
    echo "GPU_CLOCK_OBSERVABILITY=static-table-and-qualitative-level-only"
    echo "GPU_UTILIZATION_OBSERVABILITY=ioreg-PerformanceStatistics"
    echo "GPU_OVERLAP_OBSERVABILITY=xctrace-GPU-interval-duty-gaps-start-latency"
    echo "POWERMETRICS_ACCESS_BEGIN"
    sed -n '1,120p' "$OUT_DIR/powermetrics-access.txt"
    echo "POWERMETRICS_ACCESS_END"
    echo "POWER_PROFILER_ACCESS_BEGIN"
    sed -n '1,120p' "$OUT_DIR/power-profiler-access.txt"
    echo "POWER_PROFILER_ACCESS_END"
    echo "METAL_COUNTER_ACCESS_BEGIN"
    sed -n '1,120p' "$OUT_DIR/counter-access.txt"
    echo "METAL_COUNTER_ACCESS_END"
    echo "AGX_INVENTORY_BEGIN"
    sed -n '1,240p' "$OUT_DIR/agx-inventory.txt"
    echo "AGX_INVENTORY_END"
    for batch in 1 2 4; do
        cell="$OUT_DIR/b$batch"
        echo "CELL_BEGIN batch=$batch"
        echo "PREFILL_SUMMARY_BEGIN"
        sed -n '1,120p' "$cell/prefill-summary.txt"
        echo "PREFILL_SUMMARY_END"
        echo "PHYSICAL_SUMMARY_BEGIN"
        sed -n '1,240p' "$cell/physical-summary.txt"
        echo "PHYSICAL_SUMMARY_END"
        echo "TRACE_SIZE_KIB=$(sed -n '1p' "$cell/trace-size-kib.txt")"
        echo "TRACE_EXPORT_SHA256_BEGIN"
        sed -n '1,120p' "$cell/trace-export-sha256.txt"
        echo "TRACE_EXPORT_SHA256_END"
        echo "AGX_SAMPLES_BEGIN"
        sed -n '1,2000p' "$cell/agx-samples.jsonl"
        echo "AGX_SAMPLES_END"
        echo "POWER_BEFORE_BEGIN"
        sed -n '1,120p' "$cell/power-before.txt"
        echo "POWER_BEFORE_END"
        echo "POWER_AFTER_BEGIN"
        sed -n '1,120p' "$cell/power-after.txt"
        echo "POWER_AFTER_END"
        echo "XCTRACE_RECORD_BEGIN"
        sed -n '1,240p' "$cell/xctrace-record.txt"
        echo "XCTRACE_RECORD_END"
        echo "CELL_END batch=$batch"
    done
    echo "POWER_MATRIX_BEFORE_BEGIN"
    sed -n '1,120p' "$OUT_DIR/power-before.txt"
    echo "POWER_MATRIX_BEFORE_END"
    echo "POWER_MATRIX_AFTER_BEGIN"
    sed -n '1,120p' "$OUT_DIR/power-after.txt"
    echo "POWER_MATRIX_AFTER_END"
    echo "VERDICT_SCOPE=measured-cold-strict-prefill-posture"
    echo "PHYSICAL_ROOF_CLAIM=no"
    echo "HARDWARE_THEOREM=false"
} >"$OUT_DIR/result.txt"

echo "wrote $OUT_DIR/result.txt"
