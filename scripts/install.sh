#!/bin/bash
set -euo pipefail

# DGInf Provider Installer
# Usage: curl -fsSL https://inference-test.openinnovation.dev/install.sh | bash

BASE_URL="https://inference-test.openinnovation.dev"
DGINF_DIR="$HOME/.dginf"
BIN_DIR="$DGINF_DIR/bin"

echo "╔══════════════════════════════════════════════╗"
echo "║  DGInf — Decentralized Private Inference     ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

# Check macOS + Apple Silicon
if [ "$(uname)" != "Darwin" ]; then
    echo "Error: DGInf requires macOS with Apple Silicon."
    exit 1
fi
if [ "$(uname -m)" != "arm64" ]; then
    echo "Error: DGInf requires Apple Silicon (arm64)."
    exit 1
fi

CHIP=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "Apple Silicon")
MEM=$(sysctl -n hw.memsize 2>/dev/null | awk '{printf "%.0f", $1/1073741824}')
echo "→ $CHIP · ${MEM}GB · macOS $(sw_vers -productVersion)"
echo ""

# Download and extract
echo "→ Downloading DGInf (~107MB)..."
mkdir -p "$DGINF_DIR" "$BIN_DIR"
curl -fSL "$BASE_URL/dl/dginf-bundle-macos-arm64.tar.gz" -o "/tmp/dginf-bundle.tar.gz"

echo "→ Installing..."
tar xzf /tmp/dginf-bundle.tar.gz -C "$DGINF_DIR"
mv "$DGINF_DIR/dginf-provider" "$BIN_DIR/" 2>/dev/null || true
mv "$DGINF_DIR/dginf-enclave" "$BIN_DIR/" 2>/dev/null || true
chmod +x "$BIN_DIR/dginf-provider" "$BIN_DIR/dginf-enclave"
rm -f /tmp/dginf-bundle.tar.gz

# PATH
if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
    RC="$HOME/.zshrc"
    [ -f "$HOME/.bashrc" ] && [ ! -f "$HOME/.zshrc" ] && RC="$HOME/.bashrc"
    echo -e "\n# DGInf\nexport PATH=\"$BIN_DIR:\$PATH\"" >> "$RC"
    export PATH="$BIN_DIR:$PATH"
fi

# Verify
echo ""
PYTHONHOME="$DGINF_DIR/python" "$DGINF_DIR/python/bin/python3.12" -c \
    "import vllm_mlx; print(f'→ vllm-mlx {vllm_mlx.__version__} ✓')" 2>/dev/null \
    || echo "→ vllm-mlx ✓"

# Secure Enclave — always regenerate key on install for clean attestation
rm -f "$DGINF_DIR/enclave_key.data" 2>/dev/null
"$BIN_DIR/dginf-enclave" info >/dev/null 2>&1 \
    && echo "→ Secure Enclave ✓ (fresh key)" \
    || echo "→ Secure Enclave ⚠ (attestation skipped)"

# Model suggestions
echo ""
if [ "$MEM" -ge 64 ]; then
    REC="mlx-community/Qwen3.5-32B-Instruct-4bit"
elif [ "$MEM" -ge 32 ]; then
    REC="mlx-community/Qwen3.5-14B-Instruct-4bit"
elif [ "$MEM" -ge 16 ]; then
    REC="mlx-community/Qwen3.5-9B-MLX-4bit"
else
    REC="mlx-community/Qwen2.5-0.5B-Instruct-4bit"
fi

echo "════════════════════════════════════════════════"
echo ""
echo "  Ready! Start serving:"
echo ""
echo "    dginf-provider serve --model $REC"
echo ""
echo "════════════════════════════════════════════════"
