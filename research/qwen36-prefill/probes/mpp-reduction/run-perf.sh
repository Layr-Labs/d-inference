#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="${1:-$SCRIPT_DIR/perf-out}"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mpp-perf.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT
mkdir -p "$OUT_DIR"

METAL_FLAGS=(
    -std=metal4.0
    -mmacosx-version-min=26.2
)
if [[ "${MPP_RELAXED_PRECISION:-0}" == "1" ]]; then
    METAL_FLAGS+=(-DMPP_RELAXED_PRECISION=true)
fi

xcrun -sdk macosx metal \
    "${METAL_FLAGS[@]}" \
    -c "$SCRIPT_DIR/perf.metal" \
    -o "$BUILD_DIR/perf.air"
xcrun -sdk macosx metallib \
    "$BUILD_DIR/perf.air" \
    -o "$BUILD_DIR/perf.metallib"
xcrun swiftc -O -framework Metal \
    "$SCRIPT_DIR/perf.swift" \
    -o "$BUILD_DIR/mpp-perf"

RESULT="$OUT_DIR/result.txt"
{
    echo "PROBE=mpp-qwen-arithmetic-roof"
    echo "DATE_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "HOST=$(scutil --get ComputerName)"
    echo "HW_MODEL=$(sysctl -n hw.model)"
    echo "OS=$(sw_vers -productVersion)"
    echo "XCODE=$(xcodebuild -version | tr '\n' ';')"
    echo "METAL=$(xcrun metal --version | tr '\n' ';')"
    echo "MPP_RELAXED_PRECISION=${MPP_RELAXED_PRECISION:-0}"
    pmset -g batt
    pmset -g | awk '/powermode/'
    echo "SOURCE_SHA256=$(shasum -a 256 "$SCRIPT_DIR/perf.metal" "$SCRIPT_DIR/perf.swift" | tr '\n' ';')"
    "$BUILD_DIR/mpp-perf" "$BUILD_DIR/perf.metallib"
    pmset -g batt
    pmset -g | awk '/powermode/'
} | tee "$RESULT"

echo "wrote $RESULT"
