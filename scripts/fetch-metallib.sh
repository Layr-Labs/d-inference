#!/bin/bash
# fetch-metallib.sh -- pull the matching mlx.metallib for local Swift builds.
#
# mlx-swift's Cmlx target does NOT auto-compile its Metal kernels through
# SwiftPM today. Until we land a SwiftPM build-tool plugin, the local dev
# workflow is to copy the .metallib from a matching `mlx==0.31.x` Python
# wheel.
#
# The release CI does the same trick automatically (release-swift.yml step
# "Fetch matching mlx.metallib").
#
# Usage:
#   ./scripts/fetch-metallib.sh                # places mlx.metallib next to the latest debug build
#   ./scripts/fetch-metallib.sh release        # places it next to the release build
#   ./scripts/fetch-metallib.sh /custom/path   # places it at /custom/path/mlx.metallib
set -euo pipefail

# Must match MLX_PYTHON_PIN in .github/workflows/release-swift.yml and the
# MLX C++ version pinned in libs/mlx-swift/Source/Cmlx/mlx/mlx/version.h —
# patch-level skew can break Metal kernel loading at runtime.
MLX_VERSION="${MLX_VERSION:-0.31.1}"
SWIFT_PROVIDER_DIR="${SWIFT_PROVIDER_DIR:-$(cd "$(dirname "$0")/.." && pwd)/provider-swift}"
TARGET_ARG="${1:-debug}"

case "$TARGET_ARG" in
  debug)
    DEST_DIR="$SWIFT_PROVIDER_DIR/.build/debug"
    ;;
  release)
    DEST_DIR="$SWIFT_PROVIDER_DIR/.build/release"
    ;;
  /*)
    DEST_DIR="$TARGET_ARG"
    ;;
  *)
    DEST_DIR="$(pwd)/$TARGET_ARG"
    ;;
esac

mkdir -p "$DEST_DIR"

VENV_DIR="${VENV_DIR:-/tmp/mlxvenv-${MLX_VERSION}}"
if [ ! -x "$VENV_DIR/bin/python" ]; then
    echo "→ Creating venv at $VENV_DIR"
    python3 -m venv "$VENV_DIR"
fi

echo "→ Installing mlx==$MLX_VERSION (silenced)"
"$VENV_DIR/bin/pip" install --quiet --no-cache-dir "mlx==$MLX_VERSION"

# `mlx` 0.31+ ships as a namespace package (`mlx.__file__ is None`), so we
# can't go through `os.path.dirname(mlx.__file__)`. Walk site-packages
# instead -- works with both the legacy and namespace layouts.
METALLIB="$("$VENV_DIR/bin/python" - <<'PY'
import os, sys, glob
for sp in sys.path:
    for cand in glob.glob(os.path.join(sp, "mlx", "lib", "mlx.metallib")):
        print(cand); raise SystemExit(0)
raise SystemExit("mlx.metallib not found in venv site-packages")
PY
)"
test -s "$METALLIB" || { echo "✗ metallib not found at $METALLIB"; exit 1; }

cp "$METALLIB" "$DEST_DIR/mlx.metallib"
echo "✓ wrote $DEST_DIR/mlx.metallib  ($(shasum -a 256 "$DEST_DIR/mlx.metallib" | cut -d' ' -f1))"
