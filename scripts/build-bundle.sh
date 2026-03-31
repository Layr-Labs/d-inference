#!/bin/bash
set -euo pipefail

# Build the DGInf provider bundle tarball
#
# Creates a self-contained tarball with:
#   dginf-provider     Rust CLI binary (no Python linking)
#   dginf-enclave      Swift Secure Enclave CLI
#   ffmpeg             Static binary for audio transcription
#   stt_server.py      Speech-to-text server script
#   python/            Python 3.12 venv with vllm-mlx, mlx, transformers
#
# Usage:
#   ./scripts/build-bundle.sh                  # Build tarball only
#   ./scripts/build-bundle.sh --upload         # Build + upload to server
#   ./scripts/build-bundle.sh --skip-build     # Skip Rust/Swift builds (reuse existing)
#
# Requirements:
#   - macOS with Apple Silicon (arm64)
#   - Python 3.12 installed
#   - Rust toolchain (cargo)
#   - Swift toolchain (swift)
#   - SSH key at ~/.ssh/dginf-infra (for --upload)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUNDLE_DIR="/tmp/dginf-bundle"
TARBALL="/tmp/dginf-bundle-macos-arm64.tar.gz"

UPLOAD=false
SKIP_BUILD=false
for arg in "$@"; do
    case "$arg" in
        --upload) UPLOAD=true ;;
        --skip-build) SKIP_BUILD=true ;;
    esac
done

echo "╔══════════════════════════════════════════════════╗"
echo "║  DGInf Bundle Builder                            ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""

# ─── 1. Build Rust provider ──────────────────────────────────
if [ "$SKIP_BUILD" = false ]; then
    echo "1. Building dginf-provider (Rust, --no-default-features)..."
    cd "$PROJECT_DIR/provider"
    cargo build --release --no-default-features 2>&1 | tail -3
    echo "   ✓ dginf-provider ($(du -h target/release/dginf-provider | cut -f1))"
    echo ""
else
    echo "1. Skipping Rust build (--skip-build)"
    echo ""
fi

# Verify binary exists
PROVIDER_BIN="$PROJECT_DIR/provider/target/release/dginf-provider"
if [ ! -f "$PROVIDER_BIN" ]; then
    echo "   ERROR: $PROVIDER_BIN not found. Run without --skip-build."
    exit 1
fi

# ─── 2. Build Swift enclave CLI ───────────────────────────────
if [ "$SKIP_BUILD" = false ]; then
    echo "2. Building dginf-enclave (Swift)..."
    cd "$PROJECT_DIR/enclave"
    swift build -c release 2>&1 | tail -3
    echo "   ✓ dginf-enclave ($(du -h .build/release/dginf-enclave | cut -f1))"
    echo ""
else
    echo "2. Skipping Swift build (--skip-build)"
    echo ""
fi

ENCLAVE_BIN="$PROJECT_DIR/enclave/.build/release/dginf-enclave"
if [ ! -f "$ENCLAVE_BIN" ]; then
    echo "   WARNING: dginf-enclave not found. Attestation will be unavailable."
fi

# ─── 3. Create Python 3.12 venv with inference deps ──────────
echo "3. Creating Python venv with inference runtime..."
rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR"

# Find Python 3.12
PYTHON312=""
for candidate in python3.12 python3; do
    if command -v "$candidate" &>/dev/null; then
        version=$("$candidate" --version 2>&1 | awk '{print $2}')
        if [[ "$version" == 3.12.* ]]; then
            PYTHON312="$candidate"
            break
        fi
    fi
done

if [ -z "$PYTHON312" ]; then
    echo "   ERROR: Python 3.12 not found. Install it first."
    exit 1
fi

echo "   Using $PYTHON312 ($($PYTHON312 --version))"
"$PYTHON312" -m venv "$BUNDLE_DIR/python"
source "$BUNDLE_DIR/python/bin/activate"

echo "   Installing vllm-mlx (this may take a few minutes)..."
pip install --quiet vllm-mlx

echo "   Stripping unnecessary packages..."
cd "$BUNDLE_DIR/python/lib/python3.12/site-packages"
rm -rf torch* gradio* opencv* cv2* pandas* pyarrow* PIL* pillow* \
       sympy* networkx* mcp* miniaudio* pydub* datasets* Pillow*
find "$BUNDLE_DIR/python" -name __pycache__ -type d -exec rm -rf {} + 2>/dev/null || true

deactivate

PYTHON_SIZE=$(du -sh "$BUNDLE_DIR/python" | cut -f1)
echo "   ✓ Python venv ($PYTHON_SIZE)"

# Verify key packages
for pkg in mlx mlx_lm vllm_mlx huggingface_hub; do
    if [ -d "$BUNDLE_DIR/python/lib/python3.12/site-packages/$pkg" ] || \
       [ -d "$BUNDLE_DIR/python/lib/python3.12/site-packages/${pkg/-/_}" ]; then
        echo "     ✓ $pkg"
    else
        echo "     ⚠ $pkg not found"
    fi
done
echo ""

# ─── 4. Copy binaries ────────────────────────────────────────
echo "4. Copying binaries..."
cp "$PROVIDER_BIN" "$BUNDLE_DIR/dginf-provider"
echo "   ✓ dginf-provider"

if [ -f "$ENCLAVE_BIN" ]; then
    cp "$ENCLAVE_BIN" "$BUNDLE_DIR/dginf-enclave"
    echo "   ✓ dginf-enclave"
fi
echo ""

# ─── 5. Include ffmpeg static binary ─────────────────────────
echo "5. Including ffmpeg..."

# Check for a pre-downloaded ffmpeg, otherwise download one
FFMPEG_SRC=""
if [ -f "$PROJECT_DIR/vendor/ffmpeg" ]; then
    FFMPEG_SRC="$PROJECT_DIR/vendor/ffmpeg"
elif [ -f "/tmp/ffmpeg-macos-arm64" ]; then
    FFMPEG_SRC="/tmp/ffmpeg-macos-arm64"
elif command -v ffmpeg &>/dev/null; then
    # Use system ffmpeg as fallback (may not be static, but works for bundle)
    FFMPEG_SRC="$(which ffmpeg)"
fi

if [ -n "$FFMPEG_SRC" ]; then
    cp "$FFMPEG_SRC" "$BUNDLE_DIR/ffmpeg"
    chmod +x "$BUNDLE_DIR/ffmpeg"
    echo "   ✓ ffmpeg ($(du -h "$BUNDLE_DIR/ffmpeg" | cut -f1), from $FFMPEG_SRC)"
else
    echo "   ⚠ ffmpeg not found. Place a static binary at vendor/ffmpeg or /tmp/ffmpeg-macos-arm64"
    echo "     The installer will attempt to download it at install time."
fi
echo ""

# ─── 6. Include STT server script ────────────────────────────
echo "6. Including stt_server.py..."
STT_SERVER="$PROJECT_DIR/provider/stt_server.py"
if [ -f "$STT_SERVER" ]; then
    cp "$STT_SERVER" "$BUNDLE_DIR/stt_server.py"
    echo "   ✓ stt_server.py"
else
    echo "   ⚠ stt_server.py not found at $STT_SERVER"
fi
echo ""

# ─── 7. Create tarball ───────────────────────────────────────
echo "7. Creating tarball..."
rm -f "$TARBALL"
cd /tmp && tar czf "$TARBALL" -C dginf-bundle .
TARBALL_SIZE=$(du -h "$TARBALL" | cut -f1)
echo "   ✓ $TARBALL ($TARBALL_SIZE)"
echo ""

# ─── 8. Upload (optional) ────────────────────────────────────
if [ "$UPLOAD" = true ]; then
    echo "8. Uploading to server..."
    SSH_KEY="$HOME/.ssh/dginf-infra"
    SERVER="ubuntu@34.197.17.112"

    if [ ! -f "$SSH_KEY" ]; then
        echo "   ERROR: SSH key not found at $SSH_KEY"
        exit 1
    fi

    scp -i "$SSH_KEY" "$TARBALL" "$SERVER:/tmp/dginf-bundle-macos-arm64.tar.gz"
    ssh -i "$SSH_KEY" "$SERVER" '
        sudo cp /tmp/dginf-bundle-macos-arm64.tar.gz /var/www/html/dl/
        sudo chmod 644 /var/www/html/dl/dginf-bundle-macos-arm64.tar.gz
    '
    echo "   ✓ Uploaded to server"

    # Also upload the install script
    echo "   Uploading install.sh..."
    scp -i "$SSH_KEY" "$PROJECT_DIR/scripts/install.sh" "$SERVER:/tmp/install.sh"
    ssh -i "$SSH_KEY" "$SERVER" '
        sudo cp /tmp/install.sh /var/www/html/install.sh
        sudo chmod 644 /var/www/html/install.sh
    '
    echo "   ✓ install.sh uploaded"
    echo ""
fi

# ─── Summary ─────────────────────────────────────────────────
echo "════════════════════════════════════════════════════"
echo ""
echo "  Bundle: $TARBALL ($TARBALL_SIZE)"
echo ""
echo "  Contents:"
ls -lh "$BUNDLE_DIR"/ | grep -v "^total" | awk '{printf "    %-25s %s\n", $NF, $5}' 2>/dev/null || true
echo ""
if [ "$UPLOAD" = true ]; then
    echo "  Status: UPLOADED"
    echo "  Users can install with:"
    echo "    curl -fsSL https://inference-test.openinnovation.dev/install.sh | bash"
else
    echo "  To upload:"
    echo "    ./scripts/build-bundle.sh --upload"
fi
echo ""
echo "════════════════════════════════════════════════════"
