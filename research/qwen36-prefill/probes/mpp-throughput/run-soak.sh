#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="${1:-$SCRIPT_DIR/soak-out}"
SOAK_SECONDS="${MPP_SOAK_SECONDS:-300}"
ALLOW_SHORT_SOAK="${MPP_ALLOW_SHORT_SOAK:-0}"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mpp-physical-soak.XXXXXX")"
SAMPLER_PID=""
STOP_FILE="$BUILD_DIR/stop-agx-sampler"
PHASE_FILE="$BUILD_DIR/agx-phase"

cleanup() {
    if [[ -n "$SAMPLER_PID" ]] && kill -0 "$SAMPLER_PID" 2>/dev/null; then
        : >"$STOP_FILE"
        wait "$SAMPLER_PID" 2>/dev/null || true
    fi
    rm -rf "$BUILD_DIR"
}
trap cleanup EXIT

if ! [[ "$SOAK_SECONDS" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    echo "fatal: MPP_SOAK_SECONDS must be a positive number" >&2
    exit 2
fi
if ! awk -v seconds="$SOAK_SECONDS" 'BEGIN { exit(seconds > 0 ? 0 : 1) }'; then
    echo "fatal: MPP_SOAK_SECONDS must be positive" >&2
    exit 2
fi
if awk -v seconds="$SOAK_SECONDS" 'BEGIN { exit(seconds >= 300 ? 0 : 1) }'; then
    DECISION_GRADE="yes"
elif [[ "$ALLOW_SHORT_SOAK" == "1" ]]; then
    DECISION_GRADE="no"
else
    echo "fatal: decision capture requires >=300 seconds;" \
        "set MPP_ALLOW_SHORT_SOAK=1 only for smoke testing" >&2
    exit 2
fi

CANDIDATE_ID="mpp_m32_n32_k32_sg1_coop"
CANDIDATE_SOURCE="$SCRIPT_DIR/candidates.tsv"
KERNEL_SOURCE="$SCRIPT_DIR/kernel.metal"
CANDIDATE_AIR="$BUILD_DIR/$CANDIDATE_ID.air"
CANDIDATE_METALLIB="$BUILD_DIR/$CANDIDATE_ID.metallib"
ACCEPTED_MANIFEST="$BUILD_DIR/accepted-candidate.tsv"
BINARY="$BUILD_DIR/mpp-physical-soak"

RESULT="$OUT_DIR/result.txt"
PROBE_LOG="$OUT_DIR/probe.txt"
XCTRACE_LOG="$OUT_DIR/xctrace-record.txt"
TRACE_PACKAGE="$OUT_DIR/mpp-physical-soak.trace"
TRACE_TOC="$OUT_DIR/trace-toc.xml"
TRACE_EXPORT_DIR="$OUT_DIR/trace-export"
PHYSICAL_SUMMARY="$OUT_DIR/physical-summary.txt"
AGX_INVENTORY="$OUT_DIR/agx-inventory.txt"
AGX_SAMPLES="$OUT_DIR/agx-samples.jsonl"
AGX_SAMPLER_ERRORS="$OUT_DIR/agx-sampler-errors.txt"
POWER_BEFORE="$OUT_DIR/power-before.txt"
POWER_AFTER="$OUT_DIR/power-after.txt"
PROCESSES_BEFORE="$OUT_DIR/processes-before.txt"
PROCESSES_AFTER="$OUT_DIR/processes-after.txt"
POWERMETRICS_ACCESS="$OUT_DIR/powermetrics-access.txt"
XCTRACE_TEMPLATES="$OUT_DIR/xctrace-templates.txt"
GPU_METADATA="$OUT_DIR/gpu-metadata.txt"
METAL_COMPILE_LOG="$OUT_DIR/metal-compiler.txt"
METALLIB_LINK_LOG="$OUT_DIR/metallib-linker.txt"
STEEL_COMPILE_LOG="$OUT_DIR/steel-compiler.txt"
STEEL_LINK_LOG="$OUT_DIR/steel-linker.txt"
SWIFT_COMPILE_LOG="$OUT_DIR/swift-compiler.txt"
BINARY_PERF_LOG="$OUT_DIR/metal-binary-perf.txt"

if [[ -e "$TRACE_PACKAGE" ]]; then
    echo "fatal: trace output already exists: $TRACE_PACKAGE" >&2
    exit 2
fi
mkdir -p "$OUT_DIR" "$TRACE_EXPORT_DIR"

METAL_FLAGS=(
    -std=metal4.0
    -mmacosx-version-min=26.2
)

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
    echo "PMSET_CUSTOM_BEGIN"
    pmset -g custom
    echo "PMSET_CUSTOM_END"
}

capture_processes() {
    ps -axo pid,pcpu,pmem,command \
        | sort -k2 -nr \
        | sed -n '1,30p' \
        | sed 's/[[:space:]]*$//'
}

record_header() {
    echo "PROBE=mpp-fastest-valid-physical-soak"
    echo "DATE_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "HOST=$(scutil --get ComputerName)"
    echo "HW_MODEL=$(sysctl -n hw.model)"
    echo "OS=$(sw_vers -productVersion)"
    echo "OS_BUILD=$(sw_vers -buildVersion)"
    echo "XCODE=$(xcodebuild -version | tr '\n' ';')"
    echo "METAL=$(xcrun metal --version | tr '\n' ';')"
    echo "POWER_SOURCE=$(power_source)"
    echo "POWER_MODE_AC=$(ac_power_mode)"
    echo "GPU_NAME=$(awk -F': ' '/Chipset Model:/ { print $2; exit }' "$GPU_METADATA")"
    echo "SOAK_SECONDS_REQUESTED=$SOAK_SECONDS"
    echo "DECISION_GRADE=$DECISION_GRADE"
    echo "SOURCE_SHA256=$(shasum -a 256 \
        "$CANDIDATE_SOURCE" \
        "$KERNEL_SOURCE" \
        "$SCRIPT_DIR/ProbeTypes.swift" \
        "$SCRIPT_DIR/SoakRunner.swift" \
        "$SCRIPT_DIR/SoakMain.swift" \
        "$SCRIPT_DIR/agx_metrics.py" \
        "$SCRIPT_DIR/summarize_physical.py" \
        "$SCRIPT_DIR/run-soak.sh" \
        | tr '\n' ';')"
    echo "SCHEDULE_SOURCE=note-046-fastest-valid-median"
    echo "SCHEDULE=$CANDIDATE_ID"
    echo "SERVING_CODE_CHANGED=no"
    echo "HARDWARE_THEOREM=false"
}

record_invalid_gate() {
    local reason="$1"
    {
        record_header
        echo "RUN_VALID=no reason=$reason"
        echo "TIMING=skipped reason=$reason"
        echo "VERDICT=invalid hardware_theorem=false no_serving_integration=true"
    } | tee "$RESULT"
}

system_profiler SPDisplaysDataType >"$GPU_METADATA"
capture_power >"$POWER_BEFORE"
capture_processes >"$PROCESSES_BEFORE"

if [[ "$(sysctl -n hw.model)" != "Mac15,9" ]]; then
    record_invalid_gate "not-preregistered-Mac15,9"
    exit 0
fi
if ! power_gate_passes; then
    record_invalid_gate "requires-AC-High-Power"
    exit 0
fi
if pgrep -x darkbloom >"$OUT_DIR/darkbloom-pids-before.txt"; then
    record_invalid_gate "darkbloom-process-active"
    exit 0
fi

candidate_row="$(
    awk -F $'\t' -v candidate="$CANDIDATE_ID" '
        $1 == candidate { print; found++ }
        END { if (found != 1) exit 1 }
    ' "$CANDIDATE_SOURCE"
)"
IFS=$'\t' read -r \
    candidate tile_m tile_n tile_k scope scope_groups input_mode \
    <<<"$candidate_row"
if [[ "$candidate" != "$CANDIDATE_ID" ||
      "$tile_m" != "32" ||
      "$tile_n" != "32" ||
      "$tile_k" != "32" ||
      "$scope_groups" != "1" ||
      "$input_mode" != "cooperative" ]]
then
    echo "fatal: candidates.tsv no longer defines the note-046 winner" >&2
    exit 1
fi

xcrun -sdk macosx metal "${METAL_FLAGS[@]}" \
    -DCOMPILE_STEEL=1 \
    -c "$KERNEL_SOURCE" \
    -o "$BUILD_DIR/steel.air" \
    >"$STEEL_COMPILE_LOG" 2>&1
xcrun -sdk macosx metallib \
    "$BUILD_DIR/steel.air" \
    -o "$BUILD_DIR/steel.metallib" \
    >"$STEEL_LINK_LOG" 2>&1

xcrun -sdk macosx metal "${METAL_FLAGS[@]}" \
    -ftime-report=per-pass \
    -DCOMPILE_MPP_CANDIDATE=1 \
    -DMPP_TILE_M="$tile_m" \
    -DMPP_TILE_N="$tile_n" \
    -DMPP_TILE_K="$tile_k" \
    -DMPP_SCOPE_SIMDGROUPS="$scope_groups" \
    -DMPP_INPUT_MODE=1 \
    -DMPP_FUNCTION="$candidate" \
    -c "$KERNEL_SOURCE" \
    -o "$CANDIDATE_AIR" \
    >"$METAL_COMPILE_LOG" 2>&1
xcrun -sdk macosx metallib \
    "$CANDIDATE_AIR" \
    -o "$CANDIDATE_METALLIB" \
    >"$METALLIB_LINK_LOG" 2>&1

printf '#candidate\ttile_m\ttile_n\ttile_k\tscope\tscope_simdgroups\tinput_mode\tmetallib_path\n' \
    >"$ACCEPTED_MANIFEST"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$candidate" "$tile_m" "$tile_n" "$tile_k" "$scope" "$scope_groups" \
    "$input_mode" "$CANDIDATE_METALLIB" \
    >>"$ACCEPTED_MANIFEST"

xcrun swiftc -O -framework Metal \
    "$SCRIPT_DIR/ProbeTypes.swift" \
    "$SCRIPT_DIR/SoakRunner.swift" \
    "$SCRIPT_DIR/SoakMain.swift" \
    -o "$BINARY" \
    >"$SWIFT_COMPILE_LOG" 2>&1

set +e
xcrun metal-binary-perf --module-load "$CANDIDATE_METALLIB" \
    >"$BINARY_PERF_LOG" 2>&1
BINARY_PERF_STATUS=$?
/usr/bin/powermetrics --samplers gpu_power -i 100 -n 1 \
    >"$POWERMETRICS_ACCESS" 2>&1
POWERMETRICS_STATUS=$?
xcrun xctrace list templates >"$XCTRACE_TEMPLATES" 2>&1
XCTRACE_LIST_STATUS=$?
set -e

if ! awk '$0 == "Metal System Trace" { found=1 } END { exit(found ? 0 : 1) }' \
    "$XCTRACE_TEMPLATES"
then
    {
        record_header
        echo "RUN_VALID=no reason=metal-system-trace-template-unavailable"
        echo "XCTRACE_LIST_EXIT=$XCTRACE_LIST_STATUS"
        sed -n '1,240p' "$XCTRACE_TEMPLATES"
        echo "TIMING=skipped reason=trace-template-unavailable"
        echo "VERDICT=invalid hardware_theorem=false no_serving_integration=true"
    } | tee "$RESULT"
    exit 1
fi

python3 "$SCRIPT_DIR/agx_metrics.py" inventory >"$AGX_INVENTORY"
python3 "$SCRIPT_DIR/agx_metrics.py" once --phase before >"$AGX_SAMPLES"

if ! power_gate_passes; then
    record_invalid_gate "power-posture-changed-before-soak"
    exit 0
fi
if pgrep -x darkbloom >"$OUT_DIR/darkbloom-pids-presoak.txt"; then
    record_invalid_gate "darkbloom-process-active-before-soak"
    exit 0
fi

printf 'during\n' >"$PHASE_FILE"
python3 "$SCRIPT_DIR/agx_metrics.py" loop \
    --phase-file "$PHASE_FILE" \
    --stop-file "$STOP_FILE" \
    --interval 1 \
    >>"$AGX_SAMPLES" 2>"$AGX_SAMPLER_ERRORS" &
SAMPLER_PID=$!

set +e
xcrun xctrace record \
    --template "Metal System Trace" \
    --window 20s \
    --no-prompt \
    --output "$TRACE_PACKAGE" \
    --target-stdout "$PROBE_LOG" \
    --launch -- \
    "$BINARY" "$BUILD_DIR" "$ACCEPTED_MANIFEST" "$SOAK_SECONDS" \
    >"$XCTRACE_LOG" 2>&1
XCTRACE_RECORD_STATUS=$?
set -e

printf 'after\n' >"$PHASE_FILE"
python3 "$SCRIPT_DIR/agx_metrics.py" once --phase after >>"$AGX_SAMPLES"
: >"$STOP_FILE"
wait "$SAMPLER_PID"
SAMPLER_PID=""

capture_power >"$POWER_AFTER"
capture_processes >"$PROCESSES_AFTER"

TRACE_EXPORT_FAILURES=0
if [[ -d "$TRACE_PACKAGE" ]]; then
    set +e
    xcrun xctrace export \
        --input "$TRACE_PACKAGE" \
        --toc \
        --output "$TRACE_TOC" \
        >"$OUT_DIR/xctrace-export-toc.txt" 2>&1
    TOC_STATUS=$?
    set -e
    if [[ "$TOC_STATUS" -ne 0 ]]; then
        TRACE_EXPORT_FAILURES=$((TRACE_EXPORT_FAILURES + 1))
    fi
    TRACE_SCHEMAS=(
        device-thermal-state-intervals
        gpu-performance-device-state-intervals
        gpu-performance-state-intervals
        metal-gpu-state-intervals
        metal-gpu-intervals
        metal-application-command-buffer-submissions
        metal-kernel-resource-allocations
        graphics-compiler-spill-events
        gpu-counter-info
        gpu-counter-value
        metal-gpu-counter-intervals
    )
    for schema_name in "${TRACE_SCHEMAS[@]}"; do
        set +e
        xcrun xctrace export \
            --input "$TRACE_PACKAGE" \
            --xpath \
            "/trace-toc/run[@number=\"1\"]/data/table[@schema=\"$schema_name\"]" \
            --output "$TRACE_EXPORT_DIR/$schema_name.xml" \
            >"$TRACE_EXPORT_DIR/$schema_name.stderr.txt" 2>&1
        export_status=$?
        set -e
        if [[ "$export_status" -ne 0 ]]; then
            TRACE_EXPORT_FAILURES=$((TRACE_EXPORT_FAILURES + 1))
        fi
    done
else
    TOC_STATUS=1
    TRACE_EXPORT_FAILURES=1
fi

set +e
python3 "$SCRIPT_DIR/summarize_physical.py" \
    --agx-jsonl "$AGX_SAMPLES" \
    --trace-directory "$TRACE_EXPORT_DIR" \
    --perf-inventory "$AGX_INVENTORY" \
    >"$PHYSICAL_SUMMARY" 2>"$OUT_DIR/physical-summary-errors.txt"
SUMMARY_STATUS=$?
set -e

POST_POWER_GATE="pass"
if ! power_gate_passes; then
    POST_POWER_GATE="fail"
fi
PROBE_COMPLETE="no"
if [[ -f "$PROBE_LOG" ]] &&
   awk '$0 == "RUN_COMPLETE=yes" { found=1 } END { exit(found ? 0 : 1) }' \
       "$PROBE_LOG"
then
    PROBE_COMPLETE="yes"
fi

RUN_VALID="yes"
INVALID_REASON="none"
if [[ "$DECISION_GRADE" != "yes" ]]; then
    RUN_VALID="no"
    INVALID_REASON="short-smoke-only"
elif [[ "$XCTRACE_RECORD_STATUS" -ne 0 ]]; then
    RUN_VALID="no"
    INVALID_REASON="xctrace-record-failed"
elif [[ "$PROBE_COMPLETE" != "yes" ]]; then
    RUN_VALID="no"
    INVALID_REASON="probe-incomplete"
elif [[ "$POST_POWER_GATE" != "pass" ]]; then
    RUN_VALID="no"
    INVALID_REASON="power-posture-changed"
elif [[ "$TRACE_EXPORT_FAILURES" -ne 0 || "$SUMMARY_STATUS" -ne 0 ]]; then
    RUN_VALID="no"
    INVALID_REASON="telemetry-export-failed"
fi

TRACE_SIZE_KIB=0
if [[ -d "$TRACE_PACKAGE" ]]; then
    TRACE_SIZE_KIB="$(du -sk "$TRACE_PACKAGE" | awk '{ print $1 }')"
fi

{
    record_header
    echo "RUN_VALID=$RUN_VALID reason=$INVALID_REASON"
    echo "METAL_COMPILE=pass"
    echo "METALLIB_LINK=pass"
    echo "SWIFT_COMPILE=pass"
    echo "METAL_BINARY_PERF_EXIT=$BINARY_PERF_STATUS"
    echo "POWERMETRICS_UNPRIVILEGED_EXIT=$POWERMETRICS_STATUS"
    echo "XCTRACE_LIST_EXIT=$XCTRACE_LIST_STATUS"
    echo "XCTRACE_RECORD_EXIT=$XCTRACE_RECORD_STATUS"
    echo "XCTRACE_TOC_EXIT=$TOC_STATUS"
    echo "TRACE_EXPORT_FAILURES=$TRACE_EXPORT_FAILURES"
    echo "PHYSICAL_SUMMARY_EXIT=$SUMMARY_STATUS"
    echo "TRACE_SIZE_KIB=$TRACE_SIZE_KIB"
    echo "PROBE_COMPLETE=$PROBE_COMPLETE"
    echo "POWER_POST_GATE=$POST_POWER_GATE"
    echo "POWERMETRICS_ACCESS_BEGIN"
    sed -n '1,240p' "$POWERMETRICS_ACCESS"
    echo "POWERMETRICS_ACCESS_END"
    echo "AGX_INVENTORY_BEGIN"
    sed -n '1,400p' "$AGX_INVENTORY"
    echo "AGX_INVENTORY_END"
    echo "PIPELINE_COMPILER_STATISTICS_BEGIN"
    sed -n '1,2400p' "$METAL_COMPILE_LOG"
    echo "PIPELINE_COMPILER_STATISTICS_END"
    echo "METAL_BINARY_PERF_BEGIN"
    sed -n '1,400p' "$BINARY_PERF_LOG"
    echo "METAL_BINARY_PERF_END"
    echo "POWER_BEFORE_BEGIN"
    sed -n '1,260p' "$POWER_BEFORE"
    echo "POWER_BEFORE_END"
    echo "PROCESSES_BEFORE_BEGIN"
    sed -n '1,40p' "$PROCESSES_BEFORE"
    echo "PROCESSES_BEFORE_END"
    echo "XCTRACE_RECORD_BEGIN"
    sed -n '1,500p' "$XCTRACE_LOG"
    echo "XCTRACE_RECORD_END"
    echo "PROBE_OUTPUT_BEGIN"
    sed -n '1,20000p' "$PROBE_LOG"
    echo "PROBE_OUTPUT_END"
    echo "AGX_SAMPLES_BEGIN"
    sed -n '1,2000p' "$AGX_SAMPLES"
    echo "AGX_SAMPLES_END"
    echo "PHYSICAL_SUMMARY_BEGIN"
    sed -n '1,500p' "$PHYSICAL_SUMMARY"
    echo "PHYSICAL_SUMMARY_END"
    echo "TRACE_TOC_BEGIN"
    sed -n '1,320p' "$TRACE_TOC" 2>/dev/null || true
    echo "TRACE_TOC_END"
    for trace_export in "$TRACE_EXPORT_DIR"/*.xml; do
        [[ -e "$trace_export" ]] || continue
        echo "TRACE_EXPORT_BEGIN file=$(basename "$trace_export")"
        sed -n '1,5000p' "$trace_export"
        echo "TRACE_EXPORT_END file=$(basename "$trace_export")"
    done
    echo "POWER_AFTER_BEGIN"
    sed -n '1,260p' "$POWER_AFTER"
    echo "POWER_AFTER_END"
    echo "PROCESSES_AFTER_BEGIN"
    sed -n '1,40p' "$PROCESSES_AFTER"
    echo "PROCESSES_AFTER_END"
    echo "ARTIFACT_SCOPE=fastest-valid-schedule-sustained-measurement"
    echo "PHYSICAL_ROOF_CLAIM=no"
    echo "HARDWARE_THEOREM=false"
} | tee "$RESULT"

if [[ "$XCTRACE_RECORD_STATUS" -ne 0 ||
      "$PROBE_COMPLETE" != "yes" ||
      "$POST_POWER_GATE" != "pass" ||
      "$TRACE_EXPORT_FAILURES" -ne 0 ||
      "$SUMMARY_STATUS" -ne 0 ]]
then
    exit 1
fi
if [[ "$DECISION_GRADE" == "yes" && "$RUN_VALID" != "yes" ]]; then
    exit 1
fi
if ! awk '
    /^CORRECTNESS status=pass / { correctness=1 }
    /^SUSTAINED_COMPARISON / { comparison=1 }
    /^VERDICT=measured-sustained-schedule .* hardware_theorem=false$/ {
        verdict=1
    }
    END { exit(correctness && comparison && verdict ? 0 : 1) }
' "$PROBE_LOG"
then
    echo "fatal: soak output lacks correctness/comparison/scope gates" >&2
    exit 1
fi

echo "wrote $RESULT"
