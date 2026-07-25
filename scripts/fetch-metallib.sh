#!/bin/bash
# fetch-metallib.sh -- build the matching mlx.metallib for local Swift builds.
#
# NOTE: despite the name, this now BUILDS the .metallib from source rather than
# fetching it from a PyPI wheel. Building from our own fork guarantees the GPU
# kernels match the exact MLX commit the host C++ links against — including the
# resource-count trim and the M5 `_nax` kernels — and needs no published wheel
# (there is no mlx==0.32.0 on PyPI). This mirrors the release-swift.yml
# "Build mlx.metallib from source" step.
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
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SWIFT_PROVIDER_DIR="${SWIFT_PROVIDER_DIR:-$REPO_ROOT/provider-swift}"
# Source of truth: the mlx submodule the Cmlx target actually compiles against.
MLX_SRC="${MLX_SRC:-$REPO_ROOT/libs/mlx-swift/Source/Cmlx/mlx}"
# The _nax kernels are only compiled when SDK >= 26.2 AND deployment target
# >= 26.2 AND Metal >= 4.0 (mlx/backend/metal/kernels/CMakeLists.txt).
DEPLOYMENT_TARGET="${MLX_METALLIB_DEPLOYMENT_TARGET:-26.2}"
TARGET_ARG="${1:-debug}"

case "$TARGET_ARG" in
  debug)   DEST_DIR="$SWIFT_PROVIDER_DIR/.build/debug" ;;
  release) DEST_DIR="$SWIFT_PROVIDER_DIR/.build/release" ;;
  /*)      DEST_DIR="$TARGET_ARG" ;;
  *)       DEST_DIR="$(pwd)/$TARGET_ARG" ;;
esac
mkdir -p "$DEST_DIR"

command -v cmake >/dev/null 2>&1 || { echo "✗ cmake not found (brew install cmake)"; exit 1; }
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
    # Not a git checkout (source tarball, vendored copy). There is no commit
    # and no diff to read, so hashing nothing would mark ANY local edit as
    # "clean" and reintroduce exactly the bug this key is meant to prevent.
    # Hash the source contents instead.
    MLX_SHA="nogit"
    MLX_TREE_HASH="$(
        find "$MLX_SRC/mlx" -type f \( -name '*.h' -o -name '*.metal' -o -name '*.cpp' \) -print0 2>/dev/null \
            | sort -z | xargs -0 shasum -a 256 2>/dev/null | shasum -a 256 | cut -d' ' -f1
    )"
    echo "→ mlx source is not a git checkout; keying metallib on file contents (${MLX_TREE_HASH:0:12})"
fi

# Hash of empty input == a clean git tree.
MLX_CLEAN_HASH="$(printf '' | shasum -a 256 | cut -d' ' -f1)"
if [ "$MLX_SHA" != "nogit" ] && [ "$MLX_TREE_HASH" = "$MLX_CLEAN_HASH" ]; then
    # Clean tree. The key is versioned (-c2) rather than bare: entries written
    # by the PREVIOUS version of this script used the bare name and could have
    # been built from a DIRTY tree, so reusing them would resurrect the very
    # mismatch this change exists to prevent. The suffix retires them.
    MLX_TREE_SUFFIX="-c2"
else
    MLX_TREE_SUFFIX="-w${MLX_TREE_HASH:0:12}"
    if [ "$MLX_SHA" != "nogit" ]; then
        echo "→ mlx working tree is dirty; keying metallib on its contents (${MLX_TREE_HASH:0:12})"
    fi
fi

# Cache the built metallib by mlx commit + working-tree contents + deployment
# target so repeat runs are instant (the build is ~1 min). Override with
# METALLIB_CACHE_DIR.
CACHE_DIR="${METALLIB_CACHE_DIR:-/tmp/mlx-metallib-cache}"
CACHE_KEY="mlx-${MLX_SHA}${MLX_TREE_SUFFIX}-dt${DEPLOYMENT_TARGET}"
CACHED="$CACHE_DIR/${CACHE_KEY}.metallib"

if [ ! -s "$CACHED" ]; then
    echo "→ Building mlx.metallib from $MLX_SRC @ $CACHE_KEY"
    BUILD_DIR="$(mktemp -d)"
    cmake -S "$MLX_SRC" -B "$BUILD_DIR" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
        -DMLX_METAL_JIT=OFF \
        -DMLX_BUILD_TESTS=OFF -DMLX_BUILD_EXAMPLES=OFF \
        -DMLX_BUILD_BENCHMARKS=OFF -DMLX_BUILD_PYTHON_BINDINGS=OFF >/dev/null
    cmake --build "$BUILD_DIR" --target mlx-metallib -j"$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
    mkdir -p "$CACHE_DIR"
    cp "$BUILD_DIR/mlx/backend/metal/kernels/mlx.metallib" "$CACHED"
    rm -rf "$BUILD_DIR"
else
    echo "→ Using cached metallib $CACHE_KEY"
fi

# Sanity: the _nax kernels must be present, otherwise the build silently used an
# SDK/deployment target < 26.2 and we'd ship a nax-less metallib. Use `grep -c`
# (not `grep -q`): grep -q closes the pipe on first match, which makes `strings`
# on this 150 MB+ file exit via SIGPIPE and trips `set -o pipefail` — a false
# negative.
NAX_KERNELS="$(strings "$CACHED" | grep -c "_nax" || true)"
if [ "$NAX_KERNELS" -eq 0 ]; then
    echo "✗ built metallib has no _nax kernels — is your Xcode SDK / deployment target >= 26.2?"
    exit 1
fi

cp "$CACHED" "$DEST_DIR/mlx.metallib"
echo "✓ wrote $DEST_DIR/mlx.metallib  ($(shasum -a 256 "$DEST_DIR/mlx.metallib" | cut -d' ' -f1))"
