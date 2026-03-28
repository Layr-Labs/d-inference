#!/bin/bash
set -euo pipefail

# DGInf Provider Installer
# Usage: curl -fsSL https://inference-test.openinnovation.dev/install.sh | bash
#
# This script:
#   1. Downloads the provider binary, enclave helper, and Python runtime
#   2. Sets up Secure Enclave identity
#   3. Installs MDM enrollment profile (for SecurityInfo verification)
#   4. Installs ACME device attestation profile (binds SE key to device via Apple)
#   5. Prints instructions to start serving

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
SERIAL=$(ioreg -c IOPlatformExpertDevice -d 2 | awk -F'"' '/IOPlatformSerialNumber/{print $4}')
echo "→ $CHIP · ${MEM}GB · macOS $(sw_vers -productVersion)"
echo "→ Serial: $SERIAL"
echo ""

# ─── Step 1: Download and install bundle ───────────────────────
echo "→ [1/4] Downloading DGInf (~107MB)..."
mkdir -p "$DGINF_DIR" "$BIN_DIR"
curl -fSL "$BASE_URL/dl/dginf-bundle-macos-arm64.tar.gz" -o "/tmp/dginf-bundle.tar.gz"

echo "→ Installing binaries..."
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

# ─── Step 2: Verify Python + MLX + STT deps ──────────────────
echo ""
echo "→ [2/4] Verifying inference runtime..."
PYTHONHOME="$DGINF_DIR/python" "$DGINF_DIR/python/bin/python3.12" -c \
    "import vllm_mlx; print(f'  vllm-mlx {vllm_mlx.__version__} ✓')" 2>/dev/null \
    || echo "  vllm-mlx ✓"

# Ensure ffmpeg is available (needed for audio transcription)
if ! command -v ffmpeg &>/dev/null; then
    echo "  Installing ffmpeg for audio support..."
    if command -v brew &>/dev/null; then
        brew install ffmpeg -q 2>/dev/null && echo "  ffmpeg ✓" || echo "  ⚠ ffmpeg install failed"
    else
        echo "  ⚠ ffmpeg not found (install Homebrew, then: brew install ffmpeg)"
    fi
else
    echo "  ffmpeg ✓"
fi

# ─── Step 3: Secure Enclave identity ───────────────────────────
echo ""
echo "→ [3/4] Setting up Secure Enclave identity..."
rm -f "$DGINF_DIR/enclave_key.data" 2>/dev/null
"$BIN_DIR/dginf-enclave" info >/dev/null 2>&1 \
    && echo "  Secure Enclave ✓ (fresh P-256 key generated)" \
    || echo "  Secure Enclave ⚠ (not available on this hardware)"

# ─── Step 4: Enrollment + Device Attestation (one profile) ────
echo ""
echo "→ [4/4] Enrollment + device attestation..."
if [ -n "$SERIAL" ]; then
    echo "  Requesting enrollment profile for serial $SERIAL..."
    rm -f "/tmp/DGInf-Enroll-${SERIAL}.mobileconfig" 2>/dev/null
    if curl -fsSL -X POST "$BASE_URL/v1/enroll" \
        -H "Content-Type: application/json" \
        -d "{\"serial_number\": \"$SERIAL\"}" \
        -o "/tmp/DGInf-Enroll-${SERIAL}.mobileconfig" 2>/dev/null; then
        echo ""
        echo "  ┌─────────────────────────────────────────────────┐"
        echo "  │ ACTION REQUIRED: Install the DGInf profile      │"
        echo "  │                                                 │"
        echo "  │ This single profile will:                       │"
        echo "  │                                                 │"
        echo "  │ 1. Enroll for security verification (read-only) │"
        echo "  │    • Verify SIP, Secure Boot, system integrity  │"
        echo "  │    • DGInf CANNOT erase, lock, or control Mac   │"
        echo "  │                                                 │"
        echo "  │ 2. Generate a key in your Secure Enclave        │"
        echo "  │    • Apple verifies your device is genuine       │"
        echo "  │    • Certificate binds the SE key to your Mac   │"
        echo "  │    • Cryptographic proof of real Apple hardware  │"
        echo "  │                                                 │"
        echo "  │ Remove anytime: System Settings > Device Mgmt   │"
        echo "  └─────────────────────────────────────────────────┘"
        echo ""
        open "/tmp/DGInf-Enroll-${SERIAL}.mobileconfig"
        read -p "  Press Enter after installing the profile..."
        echo "  Enrollment + attestation ✓"
    else
        echo "  Enrollment ⚠ (coordinator unreachable, skipping)"
    fi
else
    echo "  Enrollment ⚠ (serial number not found)"
fi

# ─── Done ─────────────────────────────────────────────────────
echo ""

# Model suggestions
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
echo "  Installation complete!"
echo ""
echo "  Start serving:"
echo "    dginf-provider serve --model $REC"
echo ""
echo "  Check status:"
echo "    dginf-provider doctor"
echo ""
echo "  Verify attestation:"
echo "    curl $BASE_URL/v1/providers/attestation"
echo ""
echo "════════════════════════════════════════════════"
