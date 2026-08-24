#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
SNAPSHOT="${1:-/Users/benchmark/.cache/huggingface/hub/models--qwen3.6-35b-a3b-vl-mtp-mxfp8/snapshots/local}"
OUT_DIR="${2:-$SCRIPT_DIR/out}"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/qwen36-real-weight-audit.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT

if [[ ! -d "$SNAPSHOT" ]]; then
    echo "fatal: snapshot directory is missing: $SNAPSHOT" >&2
    exit 1
fi
if [[ -e "$OUT_DIR" && -n "$(ls -A "$OUT_DIR" 2>/dev/null)" ]]; then
    echo "fatal: output directory is not empty: $OUT_DIR" >&2
    exit 1
fi
mkdir -p "$OUT_DIR"

SOURCES=(
    "$SCRIPT_DIR/SafeTensors.swift"
    "$SCRIPT_DIR/Quantization.swift"
    "$SCRIPT_DIR/ExactRank.swift"
    "$SCRIPT_DIR/StructureAudit.swift"
    "$SCRIPT_DIR/RoutedTiles.swift"
    "$SCRIPT_DIR/main.swift"
)
SOURCE_SHA256="$(
    shasum -a 256 "${SOURCES[@]}" "$SCRIPT_DIR/run.sh" \
        | awk '{print $1}' \
        | shasum -a 256 \
        | awk '{print $1}'
)"
ROOT_GIT_SHA="${AUDIT_ROOT_GIT_SHA_OVERRIDE:-$(git -C "$ROOT" rev-parse HEAD)}"
PINNED_MLX_SHA="${AUDIT_PINNED_MLX_SHA_OVERRIDE:-$(git -C "$ROOT" ls-tree HEAD libs/mlx | awk '{print $3}')}"

xcrun swiftc \
    -O \
    -whole-module-optimization \
    "${SOURCES[@]}" \
    -o "$BUILD_DIR/real-weight-audit" \
    >"$OUT_DIR/swift-compiler.txt" 2>&1

"$BUILD_DIR/real-weight-audit" --self-test >"$OUT_DIR/self-test.txt" 2>&1

{
    echo "PROBE=qwen36-real-weight-structure-audit"
    echo "DATE_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "HOST=$(scutil --get ComputerName)"
    echo "HW_MODEL=$(sysctl -n hw.model)"
    echo "HW_MEMSIZE=$(sysctl -n hw.memsize)"
    echo "OS=$(sw_vers -productVersion)"
    echo "OS_BUILD=$(sw_vers -buildVersion)"
    echo "SWIFT=$(swift --version | tr '\n' ';')"
    echo "ROOT_GIT_SHA=$ROOT_GIT_SHA"
    echo "PINNED_MLX_GITLINK=$PINNED_MLX_SHA"
    echo "SOURCE_SET_SHA256=$SOURCE_SHA256"
    echo "SNAPSHOT=$SNAPSHOT"
    echo "STREAMING_CONTRACT=one-tensor-mmap-at-a-time-fixed-16MiB-shard-hash-buffer-no-MLX-model-load-no-mocks"
} >"$OUT_DIR/run-header.txt"

set +e
AUDIT_SOURCE_SHA256="$SOURCE_SHA256" \
AUDIT_ROOT_GIT_SHA="$ROOT_GIT_SHA" \
AUDIT_PINNED_MLX_SHA="$PINNED_MLX_SHA" \
    /usr/bin/time -l -o "$OUT_DIR/resource-usage.txt" \
    "$BUILD_DIR/real-weight-audit" "$SNAPSHOT" "$OUT_DIR" \
    >"$OUT_DIR/probe.txt" 2>"$OUT_DIR/probe-stderr.txt"
PROBE_STATUS=$?
set -e

{
    sed -n '1,200p' "$OUT_DIR/run-header.txt"
    echo "PROBE_EXIT=$PROBE_STATUS"
    echo "SELF_TEST_BEGIN"
    sed -n '1,200p' "$OUT_DIR/self-test.txt"
    echo "SELF_TEST_END"
    echo "SUMMARY_BEGIN"
    if [[ -f "$OUT_DIR/summary.txt" ]]; then
        sed -n '1,200p' "$OUT_DIR/summary.txt"
    else
        echo "SUMMARY_MISSING=yes"
    fi
    echo "SUMMARY_END"
    echo "RESOURCE_USAGE_BEGIN"
    sed -n '1,240p' "$OUT_DIR/resource-usage.txt"
    echo "RESOURCE_USAGE_END"
} >"$OUT_DIR/result.txt"

if [[ "$PROBE_STATUS" -ne 0 ]]; then
    sed -n '1,240p' "$OUT_DIR/result.txt"
    exit "$PROBE_STATUS"
fi
if ! grep -Fq "RUN_VALID=yes" "$OUT_DIR/summary.txt"; then
    echo "fatal: structural audit did not pass its coverage/rank gates" >&2
    exit 1
fi
if ! grep -Fq "VERDICT=model-wide-rank-factor->=39%-deletion-ruled-out" "$OUT_DIR/summary.txt"; then
    echo "fatal: exact-rank lower-bound verdict is missing" >&2
    exit 1
fi

tar -czf "$OUT_DIR/raw-results.tar.gz" \
    -C "$OUT_DIR" \
    manifest.json \
    model-config.json \
    model-index.json \
    tensors.jsonl \
    matrices.jsonl \
    routed-tiles.json \
    summary.json \
    summary.txt \
    progress.log \
    probe.txt \
    probe-stderr.txt \
    resource-usage.txt \
    run-header.txt \
    self-test.txt \
    result.txt
shasum -a 256 \
    "$OUT_DIR/raw-results.tar.gz" \
    "$OUT_DIR/result.txt" \
    >"$OUT_DIR/artifacts.sha256"

sed -n '1,240p' "$OUT_DIR/result.txt"
echo "RAW_ARCHIVE=$(shasum -a 256 "$OUT_DIR/raw-results.tar.gz" | awk '{print $1}')"
echo "wrote $OUT_DIR"
