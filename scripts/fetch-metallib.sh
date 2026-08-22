#!/bin/bash
# fetch-metallib.sh -- build the matching mlx.metallib for local Swift builds.
#
# NOTE: despite the name, this BUILDS the metallib from source rather than
# fetching a PyPI wheel. The kernels match the exact MLX source that the host
# C++ links against. This is the canonical metallib path for local,
# integration, CI, and release builds.
#
# mlx-swift's Cmlx target does NOT compile its Metal kernels through SwiftPM, so
# we compile them here with cmake from libs/mlx-swift/Source/Cmlx/mlx (the same
# source SwiftPM compiles for the host side) and copy the result next to the
# build output.
#
# Usage:
#   ./scripts/fetch-metallib.sh                # next to the latest debug build
#   ./scripts/fetch-metallib.sh release        # next to the release build
#   ./scripts/fetch-metallib.sh /custom/path   # at /custom/path/mlx.metallib
#
# Environment:
#   MLX_METALLIB_DEPLOYMENT_TARGET  -mmacosx-version-min for the kernels
#   MLX_METALLIB_OUTPUT_NAME        destination filename (default mlx.metallib)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SWIFT_PROVIDER_DIR="${SWIFT_PROVIDER_DIR:-$REPO_ROOT/provider-swift}"
# Source of truth: exactly the mlx tree the Cmlx target compiles against.
MLX_SRC="$REPO_ROOT/libs/mlx-swift/Source/Cmlx/mlx"
# The _nax kernels are only compiled when SDK >= 26.2 AND deployment target
# >= 26.2 AND Metal >= 4.0 (mlx/backend/metal/kernels/CMakeLists.txt).
DEPLOYMENT_TARGET="${MLX_METALLIB_DEPLOYMENT_TARGET:-26.2}"
OUTPUT_NAME="${MLX_METALLIB_OUTPUT_NAME:-mlx.metallib}"
NAX_DEPLOYMENT_TARGET="26.2"
JIT_MODE="OFF"
NAX_SYMBOL="_nax"
GEMV_SYMBOL="gemv"
R1_BUILDER_SYMBOL="build_gemma4_sorted_expert_tiles_bm32"
R1_BUILDER_E256_SYMBOL="build_sorted_expert_tiles_bm32_e256"
R1_KERNEL_SYMBOL="affine_gather_qmm_gemma4_expert_tiles_bfloat16_t_gs_64_b_4_alN_true_bm_32_bn_32_bk_32"
QMV_WIDE_W4_M2_SYMBOL="affine_qmv_wide_bfloat16_t_gs_64_b_4_nv_2_kl_8_batch_0"
QMV_WIDE_W4_M4_BATCHED_SYMBOL="affine_qmv_wide_bfloat16_t_gs_64_b_4_nv_4_kl_8_batch_1"
QMV_WIDE_W8_M2_SYMBOL="affine_qmv_wide_bfloat16_t_gs_64_b_8_nv_2_kl_8_batch_0"
QMV_WIDE_W8_M4_BATCHED_SYMBOL="affine_qmv_wide_bfloat16_t_gs_64_b_8_nv_4_kl_8_batch_1"
version_at_least() {
    awk -v have="$1" -v want="$2" '
        BEGIN {
            nh = split(have, h, "."); nw = split(want, w, ".")
            n = (nh > nw ? nh : nw)
            for (i = 1; i <= n; i++) {
                hi = (i <= nh ? h[i] + 0 : 0)
                wi = (i <= nw ? w[i] + 0 : 0)
                if (hi > wi) { exit 0 }
                if (hi < wi) { exit 1 }
            }
            exit 0
        }'
}

# The deployment target decides BOTH halves of the symbol contract. A metallib
# linked for 26.2 carries Metal 4.0 code that older Metal runtimes reject
# outright, so a baseline build's whole reason to exist is being free of it:
# _nax present in a baseline metallib means the deployment target silently did
# not take, and the artifact would fail to load on exactly the hosts it is for.
if version_at_least "$DEPLOYMENT_TARGET" "$NAX_DEPLOYMENT_TARGET"; then
    NAX_CONTRACT="required"
else
    NAX_CONTRACT="forbidden"
fi

required_symbols() {
    if [ "$NAX_CONTRACT" = "required" ]; then
        printf '%s\n' "$NAX_SYMBOL"
    fi
    printf '%s\n' "$GEMV_SYMBOL" "$R1_BUILDER_SYMBOL" \
        "$R1_BUILDER_E256_SYMBOL" "$R1_KERNEL_SYMBOL" \
        "$QMV_WIDE_W4_M2_SYMBOL" "$QMV_WIDE_W4_M4_BATCHED_SYMBOL" \
        "$QMV_WIDE_W8_M2_SYMBOL" "$QMV_WIDE_W8_M4_BATCHED_SYMBOL"
}

COMPLETENESS_CONTRACT="$(
    { printf '%s\n' "nax=$NAX_CONTRACT"; required_symbols; } \
        | shasum -a 256 | cut -d' ' -f1
)"
TARGET_ARG="${1:-debug}"

case "$TARGET_ARG" in
  debug)   DEST_DIR="$SWIFT_PROVIDER_DIR/.build/debug" ;;
  release) DEST_DIR="$SWIFT_PROVIDER_DIR/.build/release" ;;
  /*)      DEST_DIR="$TARGET_ARG" ;;
  *)       DEST_DIR="$(pwd)/$TARGET_ARG" ;;
esac
mkdir -p "$DEST_DIR"

command -v cmake >/dev/null 2>&1 || { echo "✗ cmake not found (brew install cmake)"; exit 1; }
command -v xcodebuild >/dev/null 2>&1 || { echo "✗ xcodebuild not found"; exit 1; }
command -v xcrun >/dev/null 2>&1 || { echo "✗ xcrun not found"; exit 1; }
test -f "$MLX_SRC/mlx/version.h" || {
  echo "✗ mlx submodule missing at $MLX_SRC"
  echo "  run: git submodule update --init --recursive"
  exit 1
}

# The commit alone is NOT a sufficient cache key: kernel work happens in the
# WORKING TREE long before it is committed, and serving a metallib built from
# different sources than the host code that dispatches into it is not a stale
# cache — it is a hang. (Observed: patching `qmm_t_impl`'s M parameter while
# reusing the pre-patch metallib wedges the GPU at 0% CPU.) So fold any
# uncommitted change — tracked diffs AND untracked files — into the key.
#
# `git diff` is normalized for determinism: --binary so binary edits actually
# change the hash instead of collapsing to "Binary files differ",
# --no-ext-diff so a user's difftool cannot alter the key, and --no-color so
# terminal settings cannot either.
compute_mlx_identity() {
    if git -C "$MLX_SRC" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        MLX_SHA="$(git -C "$MLX_SRC" rev-parse HEAD 2>/dev/null || echo nogit)"
        MLX_TREE_HASH="$({
            git -C "$MLX_SRC" diff HEAD --binary --no-ext-diff --no-color -- 2>/dev/null || true
            {
                git -C "$MLX_SRC" ls-files --others --exclude-standard 2>/dev/null || true
            } | while IFS= read -r f; do
                printf '%s\n' "$f"
                cat "$MLX_SRC/$f" 2>/dev/null || true
            done
        } | shasum -a 256 | cut -d' ' -f1)"
    else
        # Hash the entire source tree (including CMake inputs and generated
        # manifests), not just kernel extensions.
        MLX_SHA="nogit"
        MLX_TREE_HASH="$(
            find "$MLX_SRC" -type f ! -path '*/.git/*' -print0 2>/dev/null \
                | sort -z | xargs -0 shasum -a 256 2>/dev/null | shasum -a 256 | cut -d' ' -f1
        )"
    fi
}

compute_mlx_identity
INITIAL_MLX_SHA="$MLX_SHA"
INITIAL_MLX_TREE_HASH="$MLX_TREE_HASH"
if [ "$MLX_SHA" = "nogit" ]; then
    echo "→ mlx source is not a git checkout; keying metallib on file contents (${MLX_TREE_HASH:0:12})"
fi
assert_mlx_source_unchanged() {
    compute_mlx_identity
    if [ "$MLX_SHA" != "$INITIAL_MLX_SHA" ] \
        || [ "$MLX_TREE_HASH" != "$INITIAL_MLX_TREE_HASH" ]
    then
        echo "✗ MLX source changed while preparing metallib; refusing stale cache publication"
        return 1
    fi
}

# Hash of empty input == a clean git tree.
MLX_CLEAN_HASH="$(printf '' | shasum -a 256 | cut -d' ' -f1)"
if [ "$MLX_SHA" != "nogit" ] && [ "$MLX_TREE_HASH" = "$MLX_CLEAN_HASH" ]; then
    # Keep a visible clean-tree epoch; the helper and completeness contract are
    # independently folded into the toolchain hash below.
    MLX_TREE_SUFFIX="-c4"
else
    MLX_TREE_SUFFIX="-w${MLX_TREE_HASH:0:12}"
    if [ "$MLX_SHA" != "nogit" ]; then
        echo "→ mlx working tree is dirty; keying metallib on its contents (${MLX_TREE_HASH:0:12})"
    fi
fi

# Cache identity covers every input which can change generated Metal code or
# the helper's acceptance contract. In particular, a cache from another Xcode
# or SDK must never be reused merely because the source commit is identical.
XCODE_VERSION="$(xcodebuild -version | tr '\n' ';')"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
SDK_BUILD_VERSION="$(xcrun --sdk macosx --show-sdk-build-version)"
HELPER_CONTRACT_HASH="$(shasum -a 256 "$0" | cut -d' ' -f1)"
TOOLCHAIN_HASH="$(
    printf '%s\n' \
        "$XCODE_VERSION" \
        "$SDK_VERSION" \
        "$SDK_BUILD_VERSION" \
        "deployment=$DEPLOYMENT_TARGET" \
        "jit=$JIT_MODE" \
        "helper=$HELPER_CONTRACT_HASH" \
        "completeness=$COMPLETENESS_CONTRACT" \
        | shasum -a 256 | cut -d' ' -f1
)"

CACHE_DIR="${METALLIB_CACHE_DIR:-/tmp/mlx-metallib-cache}"
CACHE_KEY="mlx-${MLX_SHA}${MLX_TREE_SUFFIX}-tc${TOOLCHAIN_HASH:0:16}-dt${DEPLOYMENT_TARGET}-jitoff-c${COMPLETENESS_CONTRACT:0:12}"
CACHED="$CACHE_DIR/${CACHE_KEY}.metallib"

verify_metallib() {
    local metallib="$1"
    local symbol matches

    if [ ! -s "$metallib" ]; then
        echo "✗ metallib missing or empty: $metallib"
        return 1
    fi

    while IFS= read -r symbol; do
        # Use grep -c rather than grep -q: grep -q closes the pipe after its
        # first match, causing strings to receive SIGPIPE under pipefail.
        matches="$(strings "$metallib" | grep -F -c "$symbol" || true)"
        if [ "$matches" -eq 0 ]; then
            echo "✗ metallib missing required symbol string: $symbol"
            return 1
        fi
    done < <(required_symbols)

    if [ "$NAX_CONTRACT" = "forbidden" ]; then
        matches="$(strings "$metallib" | grep -F -c "$NAX_SYMBOL" || true)"
        if [ "$matches" -ne 0 ]; then
            echo "✗ metallib for deployment target $DEPLOYMENT_TARGET carries" \
                "$NAX_SYMBOL kernels and would be rejected by" \
                "pre-$NAX_DEPLOYMENT_TARGET Metal runtimes"
            return 1
        fi
    fi
}

mkdir -p "$CACHE_DIR"

# Serialize validation and publication for a cache key. A symlink is the
# atomic owner-bearing primitive: it never exposes a lock without PID/start
# identity. The unique target directory also provides an atomic reaper claim.
CACHE_LOCK="$CACHE_DIR/.${CACHE_KEY}.lock"
PROCESS_START_HASH="$(
    LC_ALL=C TZ=UTC ps -p $$ -o lstart= | shasum -a 256 | cut -d' ' -f1
)"
LOCK_STATE_NAME=".${CACHE_KEY}.owner-$$-$PROCESS_START_HASH"
LOCK_STATE="$CACHE_DIR/$LOCK_STATE_NAME"
mkdir "$LOCK_STATE"
LOCK_HELD=0
LOCK_ATTEMPTS=0

while :; do
    if ln -s "$LOCK_STATE_NAME" "$CACHE_LOCK" 2>/dev/null; then
        LOCK_HELD=1
        break
    fi

    lock_target="$(readlink "$CACHE_LOCK" 2>/dev/null || true)"
    case "$lock_target" in
        ".${CACHE_KEY}.owner-"*)
            owner_meta="${lock_target#".${CACHE_KEY}.owner-"}"
            owner_pid="${owner_meta%%-*}"
            owner_start_hash="${owner_meta#*-}"
            current_start_hash=""
            if kill -0 "$owner_pid" 2>/dev/null; then
                current_start_hash="$(
                    LC_ALL=C TZ=UTC ps -p "$owner_pid" -o lstart= 2>/dev/null \
                        | shasum -a 256 | cut -d' ' -f1
                )"
            fi
            if [ "$current_start_hash" != "$owner_start_hash" ]; then
                stale_state="$CACHE_DIR/$lock_target"
                # Recreate a missing target left by an interrupted release.
                if [ ! -d "$stale_state" ]; then
                    mkdir "$stale_state" 2>/dev/null || true
                fi
                if mkdir "$stale_state/reaper" 2>/dev/null; then
                    if [ "$(readlink "$CACHE_LOCK" 2>/dev/null || true)" = "$lock_target" ]; then
                        rm -f "$CACHE_LOCK"
                    fi
                    rmdir "$stale_state/reaper"
                    rmdir "$stale_state"
                    rm -rf "$CACHE_DIR"/.build-"$CACHE_KEY"."$owner_pid".*
                    rm -f "$CACHE_DIR/.${CACHE_KEY}.${owner_pid}"
                    continue
                fi
            fi
            ;;
    esac

    if [ "$LOCK_ATTEMPTS" -eq 0 ]; then
        echo "→ Waiting for concurrent metallib build $CACHE_KEY"
    fi
    LOCK_ATTEMPTS=$((LOCK_ATTEMPTS + 1))
    if [ "$LOCK_ATTEMPTS" -ge 6000 ]; then
        echo "✗ timed out waiting for metallib cache lock: $CACHE_LOCK"
        exit 1
    fi
    sleep 0.1
done

BUILD_DIR=""
CACHE_TMP=""
DEST_TMP=""
release_cache_lock() {
    if [ "$LOCK_HELD" -eq 1 ]; then
        if [ "$(readlink "$CACHE_LOCK" 2>/dev/null || true)" = "$LOCK_STATE_NAME" ]; then
            rm -f "$CACHE_LOCK"
        fi
        LOCK_HELD=0
    fi
    rmdir "$LOCK_STATE" 2>/dev/null || true
}
cleanup() {
    [ -z "$BUILD_DIR" ] || rm -rf "$BUILD_DIR"
    [ -z "$CACHE_TMP" ] || rm -f "$CACHE_TMP"
    [ -z "$DEST_TMP" ] || rm -f "$DEST_TMP"
    release_cache_lock
}
trap cleanup EXIT
trap 'exit 143' HUP INT TERM

if [ -s "$CACHED" ]; then
    if verify_metallib "$CACHED"; then
        echo "→ Using cached metallib $CACHE_KEY"
    else
        echo "→ Discarding incomplete cached metallib $CACHE_KEY"
        rm -f "$CACHED"
    fi
fi

if [ ! -s "$CACHED" ]; then
    echo "→ Building mlx.metallib from $MLX_SRC @ $CACHE_KEY"
    BUILD_DIR="$(mktemp -d "$CACHE_DIR/.build-${CACHE_KEY}.$$.XXXXXX")"
    CACHE_TMP="$CACHE_DIR/.${CACHE_KEY}.$$"

    cmake -S "$MLX_SRC" -B "$BUILD_DIR" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
        -DMLX_METAL_JIT="$JIT_MODE" \
        -DMLX_BUILD_TESTS=OFF -DMLX_BUILD_EXAMPLES=OFF \
        -DMLX_BUILD_BENCHMARKS=OFF -DMLX_BUILD_PYTHON_BINDINGS=OFF >/dev/null
    cmake --build "$BUILD_DIR" --target mlx-metallib -j"$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
    cp "$BUILD_DIR/mlx/backend/metal/kernels/mlx.metallib" "$CACHE_TMP"
    verify_metallib "$CACHE_TMP"
    assert_mlx_source_unchanged
    mv -f "$CACHE_TMP" "$CACHED"
    CACHE_TMP=""
    rm -rf "$BUILD_DIR"
    BUILD_DIR=""
fi

# Always replace the destination, even on a cache hit. A merely existing file
# may have been built from different host sources and can hang the GPU.
DEST_TMP="$DEST_DIR/.${OUTPUT_NAME}.$$"
assert_mlx_source_unchanged
cp "$CACHED" "$DEST_TMP"
mv -f "$DEST_TMP" "$DEST_DIR/$OUTPUT_NAME"
DEST_TMP=""
echo "✓ wrote $DEST_DIR/$OUTPUT_NAME  ($(shasum -a 256 "$DEST_DIR/$OUTPUT_NAME" | cut -d' ' -f1))"

release_cache_lock
trap - EXIT HUP INT TERM
