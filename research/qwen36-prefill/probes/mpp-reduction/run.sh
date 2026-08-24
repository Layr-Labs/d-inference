#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="${1:-$SCRIPT_DIR/out}"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mpp-reduction.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT
mkdir -p "$OUT_DIR"

METAL_FLAGS=(
    -std=metal4.0
    -mmacosx-version-min=26.2
)

STATIC_K8_LOG="$OUT_DIR/static-k8-compiler.txt"
if xcrun -sdk macosx metal "${METAL_FLAGS[@]}" \
    -c "$SCRIPT_DIR/static-k8-rejected.metal" \
    -o "$BUILD_DIR/static-k8.air" >"$STATIC_K8_LOG" 2>&1
then
    echo "fatal: static K=8 unexpectedly compiled" >&2
    exit 1
fi
if ! /usr/bin/grep -Fq "K must be dynamic or a multiple of 16" "$STATIC_K8_LOG"
then
    echo "fatal: static K=8 failed for an unexpected reason" >&2
    /usr/bin/sed -n '1,120p' "$STATIC_K8_LOG" >&2
    exit 1
fi

xcrun -sdk macosx metal "${METAL_FLAGS[@]}" \
    -c "$SCRIPT_DIR/probe.metal" \
    -o "$BUILD_DIR/probe.air"
xcrun -sdk macosx metallib \
    "$BUILD_DIR/probe.air" \
    -o "$BUILD_DIR/probe.metallib"
xcrun swiftc -O -framework Metal \
    "$SCRIPT_DIR/main.swift" \
    -o "$BUILD_DIR/mpp-reduction-probe"

RESULT="$OUT_DIR/result.txt"
{
    echo "PROBE=mpp-reduction-order"
    echo "DATE_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "HOST=$(scutil --get ComputerName)"
    echo "HW_MODEL=$(sysctl -n hw.model)"
    echo "OS=$(sw_vers -productVersion)"
    echo "XCODE=$(xcodebuild -version | tr '\n' ';')"
    echo "METAL=$(xcrun metal --version | tr '\n' ';')"
    echo "SOURCE_SHA256=$(shasum -a 256 "$SCRIPT_DIR/probe.metal" "$SCRIPT_DIR/main.swift" | tr '\n' ';')"
    echo "STATIC_K8_COMPILE=reject"
    /usr/bin/sed -n '/K must be dynamic or a multiple of 16/p' "$STATIC_K8_LOG"
    "$BUILD_DIR/mpp-reduction-probe" "$BUILD_DIR/probe.metallib"
} | tee "$RESULT"

echo "wrote $RESULT"
