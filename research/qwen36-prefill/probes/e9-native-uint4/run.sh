#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="${1:-$SCRIPT_DIR/out}"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/e9-native-uint4.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT
mkdir -p "$OUT_DIR"

METAL_FLAGS=(
    -std=metal4.0
    -mmacosx-version-min=26.4
)

RESULT="$OUT_DIR/result.txt"
METAL_LOG="$OUT_DIR/metal-compiler.txt"
METALLIB_LOG="$OUT_DIR/metallib-linker.txt"
SWIFT_LOG="$OUT_DIR/swift-compiler.txt"
PROBE_LOG="$OUT_DIR/probe.txt"

record_header() {
    echo "PROBE=e9-native-uint4-affine-group64"
    echo "DATE_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "HOST=$(scutil --get ComputerName)"
    echo "HW_MODEL=$(sysctl -n hw.model)"
    echo "OS=$(sw_vers -productVersion)"
    echo "XCODE=$(xcodebuild -version | tr '\n' ';')"
    echo "METAL=$(xcrun metal --version | tr '\n' ';')"
    echo "POWER_SOURCE=$(pmset -g batt | sed -n '1p')"
    echo "POWER_MODE_AC=$(pmset -g custom | awk '
        /^AC Power:/ { in_ac=1; next }
        /^[A-Za-z].*Power:/ { in_ac=0 }
        in_ac && $1 == "powermode" { print $2; exit }
    ')"
    echo "SOURCE_SHA256=$(shasum -a 256 \
        "$SCRIPT_DIR/kernel.metal" "$SCRIPT_DIR/main.swift" "$SCRIPT_DIR/run.sh" \
        | tr '\n' ';')"
}

set +e
xcrun -sdk macosx metal "${METAL_FLAGS[@]}" \
    -c "$SCRIPT_DIR/kernel.metal" \
    -o "$BUILD_DIR/kernel.air" >"$METAL_LOG" 2>&1
METAL_STATUS=$?
set -e
if [[ "$METAL_STATUS" -ne 0 ]]; then
    {
        record_header
        echo "METAL_COMPILE=reject exit=$METAL_STATUS"
        sed -n '1,240p' "$METAL_LOG"
        echo "TIMING=skipped reason=metal_compile"
        echo "VERDICT=reject reason=native_uint4_api_or_toolchain"
    } | tee "$RESULT"
    exit 0
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
        echo "METAL_COMPILE=pass"
        echo "METALLIB_LINK=reject exit=$METALLIB_STATUS"
        sed -n '1,240p' "$METALLIB_LOG"
        echo "TIMING=skipped reason=metallib_link"
        echo "VERDICT=reject reason=native_uint4_api_or_toolchain"
    } | tee "$RESULT"
    exit 0
fi

set +e
xcrun swiftc -O -framework Metal \
    "$SCRIPT_DIR/main.swift" \
    -o "$BUILD_DIR/e9-native-uint4" >"$SWIFT_LOG" 2>&1
SWIFT_STATUS=$?
set -e
if [[ "$SWIFT_STATUS" -ne 0 ]]; then
    {
        record_header
        echo "METAL_COMPILE=pass"
        echo "METALLIB_LINK=pass"
        echo "SWIFT_COMPILE=reject exit=$SWIFT_STATUS"
        sed -n '1,240p' "$SWIFT_LOG"
        echo "TIMING=skipped reason=swift_compile"
        echo "VERDICT=reject reason=harness_toolchain"
    } | tee "$RESULT"
    exit 0
fi

POWER_SOURCE="$(pmset -g batt | sed -n '1p')"
POWER_MODE="$(
    pmset -g custom | awk '
        /^AC Power:/ { in_ac=1; next }
        /^[A-Za-z].*Power:/ { in_ac=0 }
        in_ac && $1 == "powermode" { print $2; exit }
    '
)"
if [[ "$POWER_SOURCE" == *"AC Power"* && "$POWER_MODE" == "2" ]]; then
    export E9_ALLOW_TIMING=1
else
    export E9_ALLOW_TIMING=0
fi

set +e
"$BUILD_DIR/e9-native-uint4" "$BUILD_DIR/kernel.metallib" \
    >"$PROBE_LOG" 2>&1
PROBE_STATUS=$?
set -e

{
    record_header
    echo "METAL_COMPILE=pass"
    echo "METALLIB_LINK=pass"
    echo "SWIFT_COMPILE=pass"
    echo "PROBE_EXIT=$PROBE_STATUS"
    sed -n '1,240p' "$PROBE_LOG"
} | tee "$RESULT"

if [[ "$PROBE_STATUS" -eq 2 ]]; then
    if ! grep -Fq "VERDICT=reject" "$PROBE_LOG" \
        || ! grep -Fq "TIMING=skipped" "$PROBE_LOG" \
        || grep -Fq "TIMING=run" "$PROBE_LOG"
    then
        echo "fatal: rejected probe did not fail closed before timing" >&2
        exit 1
    fi
    exit 0
fi
if [[ "$PROBE_STATUS" -ne 0 ]]; then
    exit "$PROBE_STATUS"
fi
if ! grep -Fq "VERDICT=correctness-pass" "$PROBE_LOG" \
    && ! grep -Fq "VERDICT=timing-measured" "$PROBE_LOG"
then
    echo "fatal: successful probe omitted correctness verdict" >&2
    exit 1
fi
