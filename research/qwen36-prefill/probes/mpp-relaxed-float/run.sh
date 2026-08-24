#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESEARCH_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
SHARED_TYPES="$SCRIPT_DIR/../mpp-throughput/ProbeTypes.swift"
OUT_DIR="${1:-$SCRIPT_DIR/out}"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mpp-relaxed-float.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT

RESULT="$OUT_DIR/result.txt"
PROBE_LOG="$OUT_DIR/probe.txt"
METAL_LOG="$OUT_DIR/metal-compiler.txt"
LINK_LOG="$OUT_DIR/metallib-linker.txt"
SWIFT_LOG="$OUT_DIR/swift-compiler.txt"
POWER_BEFORE="$OUT_DIR/power-before.txt"
POWER_AFTER="$OUT_DIR/power-after.txt"
PROCESSES_BEFORE="$OUT_DIR/processes-before.txt"
PROCESSES_AFTER="$OUT_DIR/processes-after.txt"

mkdir -p "$OUT_DIR"

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
        | sed -n '1,25p' \
        | sed 's/[[:space:]]*$//'
}

record_header() {
    echo "PROBE=mpp-relaxed-float-full-shape"
    echo "DATE_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "HOST=$(scutil --get ComputerName)"
    echo "HW_MODEL=$(sysctl -n hw.model)"
    echo "OS=$(sw_vers -productVersion)"
    echo "OS_BUILD=$(sw_vers -buildVersion)"
    echo "XCODE=$(xcodebuild -version | tr '\n' ';')"
    echo "METAL=$(xcrun metal --version | tr '\n' ';')"
    echo "SOURCE_REVISION=$(git -C "$RESEARCH_DIR/../.." rev-parse HEAD)"
    echo "POWER_SOURCE=$(power_source)"
    echo "POWER_MODE_AC=$(ac_power_mode)"
    echo "CONTRACT=fixed-BF16-values-promoted-to-float-strict-vs-relaxed-MPP"
    echo "THRESHOLD_TFLOPS=24"
    echo "EXACT_OUTPUT_CHECKSUM_REQUIRED=no"
    echo "MODEL_QUALITY_GATE_REQUIRED=yes"
    echo "SERVING_CODE_CHANGED=no"
}

record_invalid() {
    local reason="$1"
    {
        record_header
        echo "RUN_VALID=no reason=$reason"
        echo "TIMING=skipped reason=$reason"
        echo "VERDICT=invalid no_serving_integration=true"
    } | tee "$RESULT"
}

capture_power >"$POWER_BEFORE"
capture_processes >"$PROCESSES_BEFORE"

if [[ "$(sysctl -n hw.model)" != "Mac15,9" ]]; then
    record_invalid "requires-Mac15,9"
    exit 0
fi
if ! power_gate_passes; then
    record_invalid "requires-AC-High-Power"
    exit 0
fi
if pgrep -x darkbloom >"$OUT_DIR/darkbloom-pids-before.txt"; then
    record_invalid "darkbloom-process-active"
    exit 0
fi

set +e
xcrun -sdk macosx metal \
    -std=metal4.0 \
    -mmacosx-version-min=26.4 \
    -c "$SCRIPT_DIR/kernel.metal" \
    -o "$BUILD_DIR/kernel.air" \
    >"$METAL_LOG" 2>&1
METAL_STATUS=$?
set -e
if [[ "$METAL_STATUS" -ne 0 ]]; then
    {
        record_header
        echo "RUN_VALID=no reason=metal-compile"
        echo "METAL_COMPILE=fail exit=$METAL_STATUS"
        sed -n '1,1200p' "$METAL_LOG"
        echo "TIMING=skipped reason=metal-compile"
        echo "VERDICT=invalid no_serving_integration=true"
    } | tee "$RESULT"
    exit 1
fi

set +e
xcrun -sdk macosx metallib \
    "$BUILD_DIR/kernel.air" \
    -o "$BUILD_DIR/kernel.metallib" \
    >"$LINK_LOG" 2>&1
LINK_STATUS=$?
set -e
if [[ "$LINK_STATUS" -ne 0 ]]; then
    {
        record_header
        echo "RUN_VALID=no reason=metallib-link"
        echo "METAL_COMPILE=pass"
        echo "METALLIB_LINK=fail exit=$LINK_STATUS"
        sed -n '1,1200p' "$LINK_LOG"
        echo "TIMING=skipped reason=metallib-link"
        echo "VERDICT=invalid no_serving_integration=true"
    } | tee "$RESULT"
    exit 1
fi

set +e
xcrun swiftc -O -framework Metal \
    "$SHARED_TYPES" \
    "$SCRIPT_DIR/Runner.swift" \
    "$SCRIPT_DIR/main.swift" \
    -o "$BUILD_DIR/mpp-relaxed-float-probe" \
    >"$SWIFT_LOG" 2>&1
SWIFT_STATUS=$?
set -e
if [[ "$SWIFT_STATUS" -ne 0 ]]; then
    {
        record_header
        echo "RUN_VALID=no reason=swift-compile"
        echo "METAL_COMPILE=pass"
        echo "METALLIB_LINK=pass"
        echo "SWIFT_COMPILE=fail exit=$SWIFT_STATUS"
        sed -n '1,1200p' "$SWIFT_LOG"
        echo "TIMING=skipped reason=swift-compile"
        echo "VERDICT=invalid no_serving_integration=true"
    } | tee "$RESULT"
    exit 1
fi

# Compile work is complete before the second power/process gate.
if ! power_gate_passes; then
    record_invalid "power-posture-changed-before-probe"
    exit 0
fi
if pgrep -x darkbloom >"$OUT_DIR/darkbloom-pids-preprobe.txt"; then
    record_invalid "darkbloom-process-active-before-probe"
    exit 0
fi

set +e
MPP_POWER_GATE=ac-high \
    "$BUILD_DIR/mpp-relaxed-float-probe" \
    "$BUILD_DIR/kernel.metallib" \
    >"$PROBE_LOG" 2>&1
PROBE_STATUS=$?
set -e

capture_power >"$POWER_AFTER"
capture_processes >"$PROCESSES_AFTER"

POST_GATE=pass
if ! power_gate_passes; then
    POST_GATE=fail
fi

RUN_VALID=yes
if [[ "$PROBE_STATUS" -ne 0 || "$POST_GATE" != "pass" ]]; then
    RUN_VALID=no
fi

{
    record_header
    echo "RUN_VALID=$RUN_VALID"
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

if ! awk '
    /^SUMMARY / {
        count++
        if ($0 !~ /samples=16/ || $0 !~ /gpu_complete_samples=16/) {
            bad=1
        }
    }
    END { exit(count == 18 && !bad ? 0 : 1) }
' "$PROBE_LOG"
then
    echo "fatal: expected 18 complete shape/variant summaries" >&2
    exit 1
fi
if ! awk '
    /^PERF_GATE / {
        found=1
        if ($0 !~ /threshold_tflops=24.0/) {
            bad=1
        }
    }
    END { exit(found && !bad ? 0 : 1) }
' "$PROBE_LOG"
then
    echo "fatal: weighted 24 TFLOP/s performance gate is missing" >&2
    exit 1
fi
if ! awk '
    /^VERDICT=(continue|stop) / {
        found=1
        if ($0 !~ /performance_only=true/ || $0 !~ /no_serving_integration=true/) {
            bad=1
        }
    }
    END { exit(found && !bad ? 0 : 1) }
' "$PROBE_LOG"
then
    echo "fatal: bounded performance-only verdict is missing" >&2
    exit 1
fi

echo "wrote $RESULT"
