#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="${1:-$SCRIPT_DIR/out}"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mpp-reduction-benchmark.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT
mkdir -p "$OUT_DIR"

METAL_FLAGS=(
    -std=metal4.0
    -mmacosx-version-min=26.2
)

power_source() {
    pmset -g batt | sed -n '1p'
}

power_mode_ac() {
    pmset -g custom | awk '
        /^AC Power:/ { in_ac=1; next }
        /^[A-Za-z].*Power:/ { in_ac=0 }
        in_ac && $1 == "powermode" { print $2; exit }
    '
}

SOURCE_FILES=(
    "$SCRIPT_DIR/kernel.metal"
    "$SCRIPT_DIR/Types.swift"
    "$SCRIPT_DIR/Inputs.swift"
    "$SCRIPT_DIR/Runner.swift"
    "$SCRIPT_DIR/main.swift"
    "$SCRIPT_DIR/run.sh"
)

METAL_LOG="$OUT_DIR/metal-compiler.txt"
SWIFT_LOG="$OUT_DIR/swift-compiler.txt"
PROBE_LOG="$OUT_DIR/probe.txt"
RESULT="$OUT_DIR/result.txt"

xcrun -sdk macosx metal "${METAL_FLAGS[@]}" \
    -c "$SCRIPT_DIR/kernel.metal" \
    -o "$BUILD_DIR/benchmark.air" >"$METAL_LOG" 2>&1
xcrun -sdk macosx metallib \
    "$BUILD_DIR/benchmark.air" \
    -o "$BUILD_DIR/benchmark.metallib"
xcrun swiftc -O -whole-module-optimization -framework Metal \
    "$SCRIPT_DIR/Types.swift" \
    "$SCRIPT_DIR/Inputs.swift" \
    "$SCRIPT_DIR/Runner.swift" \
    "$SCRIPT_DIR/main.swift" \
    -o "$BUILD_DIR/mpp-reduction-benchmark" >"$SWIFT_LOG" 2>&1

POWER_SOURCE_BEFORE="$(power_source)"
POWER_MODE_BEFORE="$(power_mode_ac)"
if [[ "$POWER_SOURCE_BEFORE" != *"AC Power"* || "$POWER_MODE_BEFORE" != "2" ]]; then
    {
        echo "PROBE=mpp-dynamic-k8-throughput"
        echo "POWER_SOURCE_BEFORE=$POWER_SOURCE_BEFORE"
        echo "POWER_MODE_AC_BEFORE=$POWER_MODE_BEFORE"
        echo "POWER_VALID=fail reason=requires-ac-high-power"
    } | tee "$RESULT"
    exit 1
fi

set +e
caffeinate -dimsu \
    "$BUILD_DIR/mpp-reduction-benchmark" "$BUILD_DIR/benchmark.metallib" \
    >"$PROBE_LOG" 2>&1
PROBE_STATUS=$?
set -e

POWER_SOURCE_AFTER="$(power_source)"
POWER_MODE_AFTER="$(power_mode_ac)"
if [[ "$POWER_SOURCE_AFTER" == *"AC Power"* && "$POWER_MODE_AFTER" == "2" ]]; then
    POWER_VALID=pass
else
    POWER_VALID=fail
fi

{
    echo "PROBE=mpp-dynamic-k8-throughput"
    echo "DATE_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "HOST=$(scutil --get ComputerName)"
    echo "HW_MODEL=$(sysctl -n hw.model)"
    echo "OS=$(sw_vers -productVersion)"
    echo "XCODE=$(xcodebuild -version | tr '\n' ';')"
    echo "SWIFT=$(xcrun swiftc --version | tr '\n' ';')"
    echo "METAL=$(xcrun metal --version | tr '\n' ';')"
    echo "POWER_SOURCE_BEFORE=$POWER_SOURCE_BEFORE"
    echo "POWER_MODE_AC_BEFORE=$POWER_MODE_BEFORE"
    echo "THERMAL_BEFORE=$(pmset -g therm 2>&1 | tr '\n' ';')"
    echo "SOURCE_SHA256=$(shasum -a 256 "${SOURCE_FILES[@]}" | tr '\n' ';')"
    echo "PROBE_EXIT=$PROBE_STATUS"
    sed -n '1,2000p' "$PROBE_LOG"
    echo "POWER_SOURCE_AFTER=$POWER_SOURCE_AFTER"
    echo "POWER_MODE_AC_AFTER=$POWER_MODE_AFTER"
    echo "THERMAL_AFTER=$(pmset -g therm 2>&1 | tr '\n' ';')"
    echo "POWER_VALID=$POWER_VALID"
} | tee "$RESULT"

if [[ "$PROBE_STATUS" -ne 0 || "$POWER_VALID" != "pass" ]]; then
    exit 1
fi

echo "wrote $RESULT"
