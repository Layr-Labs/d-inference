#!/bin/bash
set -euo pipefail

# DGInf Provider Installer
# Usage: curl -fsSL https://inference-test.openinnovation.dev/install.sh | bash
#
# Downloads a self-contained bundle (~92MB) with:
#   - dginf-provider (Rust binary, Apple Silicon)
#   - dginf-enclave (Swift CLI, Secure Enclave attestation)
#   - Bundled Python 3.12 + vllm-mlx + mlx + mlx-lm + transformers
#
# No pip, no Homebrew, no system Python needed.

BASE_URL="https://inference-test.openinnovation.dev"
DGINF_DIR="$HOME/.dginf"
BIN_DIR="$DGINF_DIR/bin"
COORDINATOR_WS="wss://inference-test.openinnovation.dev/ws/provider"

echo "╔══════════════════════════════════════════════╗"
echo "║  DGInf — Decentralized Private Inference     ║"
echo "║  Provider Installer                          ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

# Check macOS + Apple Silicon
if [ "$(uname)" != "Darwin" ]; then
    echo "Error: DGInf provider requires macOS with Apple Silicon."
    exit 1
fi

ARCH=$(uname -m)
if [ "$ARCH" != "arm64" ]; then
    echo "Error: DGInf provider requires Apple Silicon (arm64). Detected: $ARCH"
    exit 1
fi

echo "→ Detected: macOS $(sw_vers -productVersion) on $ARCH"

# Detect hardware
CHIP=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "Unknown")
MEM=$(sysctl -n hw.memsize 2>/dev/null | awk '{printf "%.0f", $1/1073741824}')
echo "→ Hardware: $CHIP, ${MEM}GB RAM"
echo ""

# Download and extract bundle
echo "→ Downloading DGInf bundle (~92MB)..."
mkdir -p "$DGINF_DIR"
curl -fsSL --progress-bar "$BASE_URL/dl/dginf-bundle-macos-arm64.tar.gz" -o "/tmp/dginf-bundle.tar.gz"

echo "→ Extracting..."
mkdir -p "$BIN_DIR"
tar xzf /tmp/dginf-bundle.tar.gz -C "$DGINF_DIR"

# Move binaries to bin/
mv "$DGINF_DIR/dginf-provider" "$BIN_DIR/dginf-provider" 2>/dev/null || true
mv "$DGINF_DIR/dginf-enclave" "$BIN_DIR/dginf-enclave" 2>/dev/null || true
chmod +x "$BIN_DIR/dginf-provider" "$BIN_DIR/dginf-enclave"

# Fix venv paths (they were created at /tmp/dginf-bundle/python, now at ~/.dginf/python)
if [ -f "$DGINF_DIR/python/bin/activate" ]; then
    sed -i '' "s|/tmp/dginf-bundle/python|$DGINF_DIR/python|g" "$DGINF_DIR/python/bin/activate" 2>/dev/null || true
    sed -i '' "s|/tmp/dginf-bundle/python|$DGINF_DIR/python|g" "$DGINF_DIR/python/bin/pip" 2>/dev/null || true
    sed -i '' "s|/tmp/dginf-bundle/python|$DGINF_DIR/python|g" "$DGINF_DIR/python/bin/pip3" 2>/dev/null || true
    # Fix all shebang lines in bin/
    for f in "$DGINF_DIR/python/bin/"*; do
        if [ -f "$f" ] && head -1 "$f" | grep -q "/tmp/dginf-bundle"; then
            sed -i '' "s|/tmp/dginf-bundle/python|$DGINF_DIR/python|g" "$f" 2>/dev/null || true
        fi
    done
    # Fix pyvenv.cfg
    if [ -f "$DGINF_DIR/python/pyvenv.cfg" ]; then
        sed -i '' "s|/tmp/dginf-bundle/python|$DGINF_DIR/python|g" "$DGINF_DIR/python/pyvenv.cfg" 2>/dev/null || true
    fi
fi

rm -f /tmp/dginf-bundle.tar.gz

# Add to PATH if needed
if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
    SHELL_RC="$HOME/.zshrc"
    if [ -f "$HOME/.bashrc" ] && [ ! -f "$HOME/.zshrc" ]; then
        SHELL_RC="$HOME/.bashrc"
    fi
    echo "" >> "$SHELL_RC"
    echo "# DGInf provider" >> "$SHELL_RC"
    echo "export PATH=\"$BIN_DIR:\$PATH\"" >> "$SHELL_RC"
    echo "→ Added $BIN_DIR to PATH in $SHELL_RC"
    export PATH="$BIN_DIR:$PATH"
fi

# Verify bundled Python + vllm-mlx
echo ""
echo "→ Verifying bundled inference engine..."
BUNDLED_PYTHON="$DGINF_DIR/python/bin/python3"
if "$BUNDLED_PYTHON" -c "import vllm_mlx; print(f'  ✓ vllm-mlx {vllm_mlx.__version__}')" 2>/dev/null; then
    true
elif "$BUNDLED_PYTHON" -c "import mlx_lm; print('  ✓ mlx-lm available')" 2>/dev/null; then
    true
else
    echo "  ⚠ Bundled Python verification failed — will try system Python as fallback"
fi

# Setup Secure Enclave identity
echo ""
echo "→ Setting up Secure Enclave identity..."
if "$BIN_DIR/dginf-enclave" info >/dev/null 2>&1; then
    echo "  ✓ Secure Enclave ready"
else
    echo "  ⚠ Secure Enclave not available (attestation will be skipped)"
fi

# Suggest models
echo ""
echo "→ Recommended models for ${MEM}GB RAM:"
if [ "$MEM" -ge 64 ]; then
    echo "  • mlx-community/Qwen3.5-32B-Instruct-4bit"
    echo "  • mlx-community/Qwen3.5-14B-Instruct-4bit"
elif [ "$MEM" -ge 32 ]; then
    echo "  • mlx-community/Qwen3.5-14B-Instruct-4bit"
    echo "  • mlx-community/Qwen3.5-9B-MLX-4bit"
elif [ "$MEM" -ge 16 ]; then
    echo "  • mlx-community/Qwen3.5-9B-MLX-4bit"
    echo "  • mlx-community/Qwen2.5-3B-Instruct-4bit"
else
    echo "  • mlx-community/Qwen2.5-0.5B-Instruct-4bit"
fi

echo ""
echo "════════════════════════════════════════════════"
echo "  Installation complete!"
echo ""
echo "  Start serving:"
echo "    dginf-provider serve --coordinator $COORDINATOR_WS"
echo ""
echo "  With a specific model:"
echo "    dginf-provider serve --coordinator $COORDINATOR_WS \\"
echo "      --model mlx-community/Qwen3.5-9B-MLX-4bit"
echo ""
echo "  Run diagnostics:"
echo "    dginf-provider doctor"
echo "════════════════════════════════════════════════"
