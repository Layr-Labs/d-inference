#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="${1:-$SCRIPT_DIR/out}"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mpp-tile-sweep.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT

CANDIDATE_SOURCE="$SCRIPT_DIR/candidates.tsv"
KERNEL_SOURCE="$SCRIPT_DIR/kernel.metal"
ACCEPTED_MANIFEST="$BUILD_DIR/accepted-candidates.tsv"
COMPILE_MATRIX="$OUT_DIR/compile-matrix.tsv"
RESULT="$OUT_DIR/result.txt"
PROBE_LOG="$OUT_DIR/probe.txt"
SWIFT_LOG="$OUT_DIR/swift-compiler.txt"
POWER_BEFORE="$OUT_DIR/power-before.txt"
POWER_AFTER="$OUT_DIR/power-after.txt"
PROCESSES_BEFORE="$OUT_DIR/processes-before.txt"
PROCESSES_AFTER="$OUT_DIR/processes-after.txt"
GPU_METADATA="$OUT_DIR/gpu-metadata.txt"
COMPILER_LOG_DIR="$OUT_DIR/metal-compiler"
LINKER_LOG_DIR="$OUT_DIR/metallib-linker"

mkdir -p \
    "$OUT_DIR" \
    "$BUILD_DIR/candidates" \
    "$COMPILER_LOG_DIR" \
    "$LINKER_LOG_DIR"

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

capture_power() {
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
        | sed -n '1,25p' \
        | sed 's/[[:space:]]*$//'
}

power_gate_passes() {
    [[ "$(power_source)" == *"AC Power"* && "$(ac_power_mode)" == "2" ]]
}

record_header() {
    echo "PROBE=mpp-bounded-tile-execution-scope-sweep"
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
    echo "SOURCE_SHA256=$(shasum -a 256 \
        "$CANDIDATE_SOURCE" \
        "$KERNEL_SOURCE" \
        "$SCRIPT_DIR/ProbeTypes.swift" \
        "$SCRIPT_DIR/MetalRunner.swift" \
        "$SCRIPT_DIR/main.swift" \
        "$SCRIPT_DIR/run.sh" \
        | tr '\n' ';')"
    echo "CONTRACT=strict-BF16xBF16-to-FP32-cooperative-or-tensor-input-cooperative-store"
    echo "THRESHOLD_TFLOPS=22"
    echo "SERVING_CODE_CHANGED=no"
}

record_invalid_gate() {
    local reason="$1"
    {
        record_header
        echo "RUN_VALID=no reason=$reason"
        echo "TIMING=skipped reason=$reason"
        echo "VERDICT=invalid reason=$reason no_serving_integration=true"
    } | tee "$RESULT"
}

record_rejection_logs() {
    local candidate tile_m tile_n tile_k scope scope_groups input_mode
    local compile_status link_status
    while IFS=$'\t' read -r \
        candidate tile_m tile_n tile_k scope scope_groups input_mode \
        compile_status link_status
    do
        [[ -z "$candidate" || "$candidate" == \#* ]] && continue
        if [[ "$compile_status" != "pass" ]]; then
            echo "METAL_REJECTION_BEGIN candidate=$candidate"
            sed -n '1,1200p' "$COMPILER_LOG_DIR/$candidate.txt"
            echo "METAL_REJECTION_END candidate=$candidate"
        elif [[ "$link_status" != "pass" ]]; then
            echo "METALLIB_REJECTION_BEGIN candidate=$candidate"
            sed -n '1,1200p' "$LINKER_LOG_DIR/$candidate.txt"
            echo "METALLIB_REJECTION_END candidate=$candidate"
        fi
    done <"$COMPILE_MATRIX"
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

# The Steel control is isolated from every candidate AIR so a rejected MPP
# descriptor cannot suppress the reference pipeline.
set +e
xcrun -sdk macosx metal "${METAL_FLAGS[@]}" \
    -DCOMPILE_STEEL=1 \
    -c "$KERNEL_SOURCE" \
    -o "$BUILD_DIR/steel.air" \
    >"$COMPILER_LOG_DIR/steel.txt" 2>&1
STEEL_METAL_STATUS=$?
set -e
if [[ "$STEEL_METAL_STATUS" -ne 0 ]]; then
    {
        record_header
        echo "RUN_VALID=no reason=steel-metal-compile"
        echo "STEEL_METAL_COMPILE=fail exit=$STEEL_METAL_STATUS"
        sed -n '1,1200p' "$COMPILER_LOG_DIR/steel.txt"
        echo "TIMING=skipped reason=steel-metal-compile"
        echo "VERDICT=invalid reason=probe-build no_serving_integration=true"
    } | tee "$RESULT"
    exit 1
fi

set +e
xcrun -sdk macosx metallib \
    "$BUILD_DIR/steel.air" \
    -o "$BUILD_DIR/steel.metallib" \
    >"$LINKER_LOG_DIR/steel.txt" 2>&1
STEEL_LINK_STATUS=$?
set -e
if [[ "$STEEL_LINK_STATUS" -ne 0 ]]; then
    {
        record_header
        echo "RUN_VALID=no reason=steel-metallib-link"
        echo "STEEL_METAL_COMPILE=pass"
        echo "STEEL_METALLIB_LINK=fail exit=$STEEL_LINK_STATUS"
        sed -n '1,1200p' "$LINKER_LOG_DIR/steel.txt"
        echo "TIMING=skipped reason=steel-metallib-link"
        echo "VERDICT=invalid reason=probe-build no_serving_integration=true"
    } | tee "$RESULT"
    exit 1
fi

printf '#candidate\ttile_m\ttile_n\ttile_k\tscope\tscope_simdgroups\tinput_mode\tmetal_compile\tmetallib_link\n' \
    >"$COMPILE_MATRIX"
printf '#candidate\ttile_m\ttile_n\ttile_k\tscope\tscope_simdgroups\tinput_mode\tmetallib_path\n' \
    >"$ACCEPTED_MANIFEST"

REQUESTED_COUNT=0
COMPILED_COUNT=0
LINKED_COUNT=0
while IFS=$'\t' read -r \
    candidate tile_m tile_n tile_k scope scope_groups input_mode
do
    [[ -z "$candidate" || "$candidate" == \#* ]] && continue
    REQUESTED_COUNT=$((REQUESTED_COUNT + 1))
    candidate_air="$BUILD_DIR/candidates/$candidate.air"
    candidate_metallib="$BUILD_DIR/candidates/$candidate.metallib"
    case "$input_mode" in
        cooperative)
            input_mode_value=1
            ;;
        tensor)
            input_mode_value=2
            ;;
        *)
            echo "fatal: unsupported input mode $input_mode for $candidate" >&2
            exit 1
            ;;
    esac

    set +e
    xcrun -sdk macosx metal "${METAL_FLAGS[@]}" \
        -DCOMPILE_MPP_CANDIDATE=1 \
        -DMPP_TILE_M="$tile_m" \
        -DMPP_TILE_N="$tile_n" \
        -DMPP_TILE_K="$tile_k" \
        -DMPP_SCOPE_SIMDGROUPS="$scope_groups" \
        -DMPP_INPUT_MODE="$input_mode_value" \
        -DMPP_FUNCTION="$candidate" \
        -c "$KERNEL_SOURCE" \
        -o "$candidate_air" \
        >"$COMPILER_LOG_DIR/$candidate.txt" 2>&1
    metal_status=$?
    set -e
    if [[ "$metal_status" -ne 0 ]]; then
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\tfail\tnot-run\n' \
            "$candidate" "$tile_m" "$tile_n" "$tile_k" "$scope" "$scope_groups" \
            "$input_mode" \
            >>"$COMPILE_MATRIX"
        continue
    fi
    COMPILED_COUNT=$((COMPILED_COUNT + 1))

    set +e
    xcrun -sdk macosx metallib \
        "$candidate_air" \
        -o "$candidate_metallib" \
        >"$LINKER_LOG_DIR/$candidate.txt" 2>&1
    link_status=$?
    set -e
    if [[ "$link_status" -ne 0 ]]; then
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\tpass\tfail\n' \
            "$candidate" "$tile_m" "$tile_n" "$tile_k" "$scope" "$scope_groups" \
            "$input_mode" \
            >>"$COMPILE_MATRIX"
        continue
    fi
    LINKED_COUNT=$((LINKED_COUNT + 1))
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\tpass\tpass\n' \
        "$candidate" "$tile_m" "$tile_n" "$tile_k" "$scope" "$scope_groups" \
        "$input_mode" \
        >>"$COMPILE_MATRIX"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$candidate" "$tile_m" "$tile_n" "$tile_k" "$scope" "$scope_groups" \
        "$input_mode" "$candidate_metallib" \
        >>"$ACCEPTED_MANIFEST"
done <"$CANDIDATE_SOURCE"

set +e
xcrun swiftc -O -framework Metal \
    "$SCRIPT_DIR/ProbeTypes.swift" \
    "$SCRIPT_DIR/MetalRunner.swift" \
    "$SCRIPT_DIR/main.swift" \
    -o "$BUILD_DIR/mpp-throughput-probe" >"$SWIFT_LOG" 2>&1
SWIFT_STATUS=$?
set -e
if [[ "$SWIFT_STATUS" -ne 0 ]]; then
    {
        record_header
        echo "RUN_VALID=no reason=swift-compile"
        echo "STEEL_METAL_COMPILE=pass"
        echo "STEEL_METALLIB_LINK=pass"
        echo "COMPILE_COUNTS requested=$REQUESTED_COUNT compiled=$COMPILED_COUNT linked=$LINKED_COUNT"
        echo "COMPILE_MATRIX_BEGIN"
        sed -n '1,240p' "$COMPILE_MATRIX"
        echo "COMPILE_MATRIX_END"
        record_rejection_logs
        echo "SWIFT_COMPILE=fail exit=$SWIFT_STATUS"
        sed -n '1,1200p' "$SWIFT_LOG"
        echo "TIMING=skipped reason=swift-compile"
        echo "VERDICT=invalid reason=probe-build no_serving_integration=true"
    } | tee "$RESULT"
    exit 1
fi

# Compilation is complete before this second posture gate. No benchmark process
# starts unless the machine is still on AC / High Power and Darkbloom is absent.
if ! power_gate_passes; then
    record_invalid_gate "power-posture-changed-before-probe"
    exit 0
fi
if pgrep -x darkbloom >"$OUT_DIR/darkbloom-pids-preprobe.txt"; then
    record_invalid_gate "darkbloom-process-active-before-probe"
    exit 0
fi

set +e
MPP_POWER_GATE=ac-high \
    "$BUILD_DIR/mpp-throughput-probe" \
    "$BUILD_DIR" \
    "$ACCEPTED_MANIFEST" \
    >"$PROBE_LOG" 2>&1
PROBE_STATUS=$?
set -e

capture_power >"$POWER_AFTER"
capture_processes >"$PROCESSES_AFTER"

POST_GATE="pass"
if ! power_gate_passes; then
    POST_GATE="fail"
fi

RUN_VALID="yes"
if [[ "$POST_GATE" != "pass" || "$PROBE_STATUS" -ne 0 ]]; then
    RUN_VALID="no"
fi

{
    record_header
    echo "RUN_VALID=$RUN_VALID"
    echo "STEEL_METAL_COMPILE=pass"
    echo "STEEL_METALLIB_LINK=pass"
    echo "SWIFT_COMPILE=pass"
    echo "COMPILE_COUNTS requested=$REQUESTED_COUNT compiled=$COMPILED_COUNT linked=$LINKED_COUNT"
    echo "COMPILE_MATRIX_BEGIN"
    sed -n '1,240p' "$COMPILE_MATRIX"
    echo "COMPILE_MATRIX_END"
    record_rejection_logs
    echo "PROBE_EXIT=$PROBE_STATUS"
    echo "POWER_POST_GATE=$POST_GATE"
    echo "GPU_METADATA_BEGIN"
    sed -n '1,240p' "$GPU_METADATA"
    echo "GPU_METADATA_END"
    echo "POWER_BEFORE_BEGIN"
    sed -n '1,240p' "$POWER_BEFORE"
    echo "POWER_BEFORE_END"
    echo "PROCESSES_BEFORE_BEGIN"
    sed -n '1,40p' "$PROCESSES_BEFORE"
    echo "PROCESSES_BEFORE_END"
    echo "PROBE_OUTPUT_BEGIN"
    sed -n '1,12000p' "$PROBE_LOG"
    echo "PROBE_OUTPUT_END"
    echo "POWER_AFTER_BEGIN"
    sed -n '1,240p' "$POWER_AFTER"
    echo "POWER_AFTER_END"
    echo "PROCESSES_AFTER_BEGIN"
    sed -n '1,40p' "$PROCESSES_AFTER"
    echo "PROCESSES_AFTER_END"
} | tee "$RESULT"

if [[ "$POST_GATE" != "pass" ]]; then
    echo "fatal: AC/High Power posture changed during the run" >&2
    exit 1
fi
if [[ "$PROBE_STATUS" -ne 0 ]]; then
    exit "$PROBE_STATUS"
fi

if ! grep -Fq "PIPELINE_MATRIX linked=$LINKED_COUNT " "$PROBE_LOG"; then
    echo "fatal: pipeline matrix does not cover every linked candidate" >&2
    exit 1
fi
if ! grep -Eq '^CORRECTNESS_GATE executable=[0-9]+ runtime_rejected=[0-9]+ numerical_rejected=[0-9]+ valid=[1-9][0-9]*$' \
    "$PROBE_LOG"
then
    echo "fatal: correctness matrix did not retain a valid candidate" >&2
    exit 1
fi
if ! grep -Eq '^TIMING_GATE valid_before_timing=[0-9]+ timing_rejected=[0-9]+ fully_timed=[1-9][0-9]* samples_per_candidate_shape=16$' \
    "$PROBE_LOG"
then
    echo "fatal: timing matrix is incomplete" >&2
    exit 1
fi
if awk '
    /^SUMMARY / {
        count++
        if ($0 !~ / samples=16 / || $0 !~ / gpu_complete_samples=16 /) {
            bad=1
        }
    }
    END { exit(count > 0 && !bad ? 0 : 1) }
' "$PROBE_LOG"
then
    :
else
    echo "fatal: one or more summaries lack 16 GPU-complete samples" >&2
    exit 1
fi
if ! grep -Eq '^BOUNDED_MAX_VALID_MEDIAN .* threshold_tflops=22\.0 .* hardware_theorem=false$' \
    "$PROBE_LOG"
then
    echo "fatal: bounded maximum median is missing" >&2
    exit 1
fi
if ! grep -Eq '^VERDICT=(continue|stop) .* bounded_sweep_only=true hardware_theorem=false no_serving_integration=true$' \
    "$PROBE_LOG"
then
    echo "fatal: bounded >=22 TFLOPS verdict is missing" >&2
    exit 1
fi

echo "wrote $RESULT"
