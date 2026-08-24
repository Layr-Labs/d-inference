#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="${1:-$SCRIPT_DIR/out}"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mpp-throughput.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT
mkdir -p "$OUT_DIR"

RESULT="$OUT_DIR/result.txt"
METAL_LOG="$OUT_DIR/metal-compiler.txt"
METALLIB_LOG="$OUT_DIR/metallib-linker.txt"
SWIFT_LOG="$OUT_DIR/swift-compiler.txt"
PROBE_LOG="$OUT_DIR/probe.txt"
POWER_BEFORE="$OUT_DIR/power-before.txt"
POWER_AFTER="$OUT_DIR/power-after.txt"
PROCESSES_BEFORE="$OUT_DIR/processes-before.txt"
PROCESSES_AFTER="$OUT_DIR/processes-after.txt"
GPU_METADATA="$OUT_DIR/gpu-metadata.txt"

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
    ps -axo pid,pcpu,pmem,command | sort -k2 -nr | sed -n '1,25p'
}

power_gate_passes() {
    [[ "$(power_source)" == *"AC Power"* && "$(ac_power_mode)" == "2" ]]
}

record_header() {
    echo "PROBE=mpp-supported-static-k16-throughput"
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
        "$SCRIPT_DIR/kernel.metal" \
        "$SCRIPT_DIR/ProbeTypes.swift" \
        "$SCRIPT_DIR/MetalRunner.swift" \
        "$SCRIPT_DIR/main.swift" \
        "$SCRIPT_DIR/run.sh" \
        | tr '\n' ';')"
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

set +e
xcrun -sdk macosx metal "${METAL_FLAGS[@]}" \
    -c "$SCRIPT_DIR/kernel.metal" \
    -o "$BUILD_DIR/kernel.air" >"$METAL_LOG" 2>&1
METAL_STATUS=$?
set -e
if [[ "$METAL_STATUS" -ne 0 ]]; then
    {
        record_header
        echo "RUN_VALID=no reason=metal-compile"
        echo "METAL_COMPILE=fail exit=$METAL_STATUS"
        sed -n '1,240p' "$METAL_LOG"
        echo "TIMING=skipped reason=metal-compile"
        echo "VERDICT=invalid reason=probe-build no_serving_integration=true"
    } | tee "$RESULT"
    exit 1
fi

set +e
xcrun -sdk macosx metallib \
    "$BUILD_DIR/kernel.air" \
    -o "$BUILD_DIR/kernel.metallib" >"$METALLIB_LOG" 2>&1
METALLIB_STATUS=$?
set -e
if [[ "$METALLIB_STATUS" -ne 0 ]]; then
    {
        record_header
        echo "RUN_VALID=no reason=metallib-link"
        echo "METAL_COMPILE=pass"
        echo "METALLIB_LINK=fail exit=$METALLIB_STATUS"
        sed -n '1,240p' "$METALLIB_LOG"
        echo "TIMING=skipped reason=metallib-link"
        echo "VERDICT=invalid reason=probe-build no_serving_integration=true"
    } | tee "$RESULT"
    exit 1
fi

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
        echo "METAL_COMPILE=pass"
        echo "METALLIB_LINK=pass"
        echo "SWIFT_COMPILE=fail exit=$SWIFT_STATUS"
        sed -n '1,240p' "$SWIFT_LOG"
        echo "TIMING=skipped reason=swift-compile"
        echo "VERDICT=invalid reason=probe-build no_serving_integration=true"
    } | tee "$RESULT"
    exit 1
fi

# Compilation is complete before this second gate. No benchmark process is
# launched unless posture is still valid and the provider remains stopped.
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
    "$BUILD_DIR/mpp-throughput-probe" "$BUILD_DIR/kernel.metallib" \
    >"$PROBE_LOG" 2>&1
PROBE_STATUS=$?
set -e

capture_power >"$POWER_AFTER"
capture_processes >"$PROCESSES_AFTER"

POST_GATE="pass"
if ! power_gate_passes; then
    POST_GATE="fail"
fi

{
    record_header
    echo "RUN_VALID=$([[ "$POST_GATE" == "pass" ]] && echo yes || echo no)"
    echo "METAL_COMPILE=pass"
    echo "METALLIB_LINK=pass"
    echo "SWIFT_COMPILE=pass"
    echo "PROBE_EXIT=$PROBE_STATUS"
    echo "POWER_POST_GATE=$POST_GATE"
    echo "POWER_BEFORE_BEGIN"
    sed -n '1,240p' "$POWER_BEFORE"
    echo "POWER_BEFORE_END"
    echo "PROCESSES_BEFORE_BEGIN"
    sed -n '1,40p' "$PROCESSES_BEFORE"
    echo "PROCESSES_BEFORE_END"
    echo "PROBE_OUTPUT_BEGIN"
    sed -n '1,2000p' "$PROBE_LOG"
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

if [[ "$PROBE_STATUS" -eq 2 ]]; then
    if ! grep -Fq "CORRECTNESS_GATE=fail" "$PROBE_LOG" \
        || ! grep -Fq "TIMING=skipped reason=steel_correctness_gate" "$PROBE_LOG" \
        || grep -q '^SAMPLE ' "$PROBE_LOG"
    then
        echo "fatal: correctness rejection did not fail closed" >&2
        exit 1
    fi
    exit 0
fi
if [[ "$PROBE_STATUS" -ne 0 ]]; then
    exit "$PROBE_STATUS"
fi

if [[ "$(grep -c '^SUMMARY .*arm=mpp samples=16 ' "$PROBE_LOG")" -ne 8 ]] \
    || [[ "$(grep -c '^SUMMARY .*arm=steel samples=16 ' "$PROBE_LOG")" -ne 8 ]]
then
    echo "fatal: probe did not record 16 samples per arm for all eight shapes" >&2
    exit 1
fi
if [[ "$(grep -c '^SAMPLE .*gpu_complete=yes ' "$PROBE_LOG")" -ne 256 ]]; then
    echo "fatal: probe did not record 256 GPU-complete A/B samples" >&2
    exit 1
fi
if ! grep -Eq '^VERDICT=(continue|stop) ' "$PROBE_LOG"; then
    echo "fatal: measured probe omitted the >=22 TFLOPS verdict" >&2
    exit 1
fi

echo "wrote $RESULT"
