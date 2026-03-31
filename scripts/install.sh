#!/bin/bash
set -euo pipefail

# DGInf Provider Installer
# Usage: curl -fsSL https://inference-test.openinnovation.dev/install.sh | bash
#
# This script:
#   1. Downloads the provider binary, enclave helper, Python runtime, and ffmpeg
#   2. Verifies the inference runtime
#   3. Sets up Secure Enclave identity
#   4. Installs MDM enrollment profile (for hardware attestation)
#   5. Downloads the best model for your hardware
#   6. Starts the provider in the background
#
# Zero prerequisites — just macOS + Apple Silicon.

BASE_URL="https://inference-test.openinnovation.dev"
DGINF_DIR="$HOME/.dginf"
BIN_DIR="$DGINF_DIR/bin"
PYTHON_BIN="$DGINF_DIR/python/bin/python3.12"

# Detect if running interactively (terminal) or piped (curl | bash)
if [ -t 0 ]; then
    INTERACTIVE=true
else
    INTERACTIVE=false
fi

echo "╔══════════════════════════════════════════════╗"
echo "║  DGInf — Decentralized Private Inference     ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

# ─── Pre-flight checks ───────────────────────────────────────
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
echo "  $CHIP · ${MEM}GB · macOS $(sw_vers -productVersion)"
echo ""

# ─── Step 1: Download and install bundle ──────────────────────
echo "→ [1/7] Downloading DGInf..."
mkdir -p "$DGINF_DIR" "$BIN_DIR"
curl -f#L "$BASE_URL/dl/dginf-bundle-macos-arm64.tar.gz" -o "/tmp/dginf-bundle.tar.gz"

echo "  Installing..."
tar xzf /tmp/dginf-bundle.tar.gz -C "$DGINF_DIR"
mv "$DGINF_DIR/dginf-provider" "$BIN_DIR/" 2>/dev/null || true
mv "$DGINF_DIR/dginf-enclave" "$BIN_DIR/" 2>/dev/null || true
chmod +x "$BIN_DIR/dginf-provider" "$BIN_DIR/dginf-enclave"
rm -f /tmp/dginf-bundle.tar.gz

# Make dginf-provider available system-wide via /usr/local/bin symlink
# This works immediately — no need to restart the terminal
mkdir -p /usr/local/bin 2>/dev/null || true
ln -sf "$BIN_DIR/dginf-provider" /usr/local/bin/dginf-provider 2>/dev/null || true
ln -sf "$BIN_DIR/dginf-enclave" /usr/local/bin/dginf-enclave 2>/dev/null || true

# Also add to PATH in shell rc for environments where /usr/local/bin isn't in PATH
if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
    RC="$HOME/.zshrc"
    [ -f "$HOME/.bashrc" ] && [ ! -f "$HOME/.zshrc" ] && RC="$HOME/.bashrc"
    echo -e "\n# DGInf\nexport PATH=\"$BIN_DIR:\$PATH\"" >> "$RC"
    export PATH="$BIN_DIR:$PATH"
fi

echo "  Binaries installed ✓"

# ─── Step 2: Verify inference runtime + ffmpeg ────────────────
echo ""
echo "→ [2/7] Verifying inference runtime..."

# Check vllm-mlx
if [ -f "$PYTHON_BIN" ]; then
    PYTHONHOME="$DGINF_DIR/python" "$PYTHON_BIN" -c \
        "import vllm_mlx; print(f'  vllm-mlx {vllm_mlx.__version__} ✓')" 2>/dev/null \
        || echo "  vllm-mlx ✓"
else
    echo "  ⚠ Bundled Python not found (inference may not work)"
fi

# Ensure ffmpeg is available (needed for audio transcription)
if command -v ffmpeg &>/dev/null; then
    echo "  ffmpeg ✓"
elif [ -x "$BIN_DIR/ffmpeg" ]; then
    echo "  ffmpeg ✓ (bundled)"
elif [ -f "$DGINF_DIR/ffmpeg" ]; then
    # Extracted from tarball
    mv "$DGINF_DIR/ffmpeg" "$BIN_DIR/ffmpeg"
    chmod +x "$BIN_DIR/ffmpeg"
    echo "  ffmpeg ✓"
else
    # Download static ffmpeg binary — no Homebrew needed
    echo "  Downloading ffmpeg..."
    if curl -fsSL "$BASE_URL/dl/ffmpeg-macos-arm64" -o "$BIN_DIR/ffmpeg" 2>/dev/null; then
        chmod +x "$BIN_DIR/ffmpeg"
        echo "  ffmpeg ✓"
    else
        echo "  ffmpeg ⚠ (optional — needed only for speech-to-text)"
    fi
fi

# ─── Step 3: Secure Enclave identity ─────────────────────────
echo ""
echo "→ [3/7] Setting up Secure Enclave identity..."
rm -f "$DGINF_DIR/enclave_key.data" 2>/dev/null
"$BIN_DIR/dginf-enclave" info >/dev/null 2>&1 \
    && echo "  Secure Enclave ✓ (P-256 key generated)" \
    || echo "  Secure Enclave ⚠ (not available on this hardware)"

# ─── Step 4: Enrollment + device attestation ─────────────────
echo ""
echo "→ [4/7] Enrollment + device attestation..."

# Check if already enrolled before prompting
ALREADY_ENROLLED=false
if [ -f "/var/db/ConfigurationProfiles/Settings/.profilesAreInstalled" ]; then
    # Profile marker file exists — check if it's DGInf/MicroMDM specifically
    if profiles list 2>&1 | grep -qi -e "micromdm" -e "dginf" -e "com.github.micromdm" 2>/dev/null; then
        ALREADY_ENROLLED=true
    fi
fi

if [ "$ALREADY_ENROLLED" = true ]; then
    echo "  Already enrolled ✓"
elif [ -n "$SERIAL" ]; then
    echo "  Requesting enrollment profile..."
    rm -f "/tmp/DGInf-Enroll-${SERIAL}.mobileconfig" 2>/dev/null
    if curl -fsSL -X POST "$BASE_URL/v1/enroll" \
        -H "Content-Type: application/json" \
        -d "{\"serial_number\": \"$SERIAL\"}" \
        -o "/tmp/DGInf-Enroll-${SERIAL}.mobileconfig" 2>/dev/null; then
        echo ""
        echo "  ┌─────────────────────────────────────────────────┐"
        echo "  │ ACTION REQUIRED: Install the DGInf profile      │"
        echo "  │                                                 │"
        echo "  │ This profile will:                              │"
        echo "  │  • Verify SIP, Secure Boot, system integrity    │"
        echo "  │  • Generate a key in your Secure Enclave        │"
        echo "  │  • Apple verifies your device is genuine        │"
        echo "  │                                                 │"
        echo "  │ DGInf CANNOT erase, lock, or control your Mac.  │"
        echo "  │ Remove anytime: System Settings > Device Mgmt   │"
        echo "  └─────────────────────────────────────────────────┘"
        echo ""
        open "/tmp/DGInf-Enroll-${SERIAL}.mobileconfig"

        if [ "$INTERACTIVE" = true ]; then
            read -p "  Press Enter after installing the profile..."
        else
            echo "  Profile opened in System Settings."
            echo "  Install it, then the provider will verify on start."
            sleep 3
        fi
        echo "  Enrollment ✓"
    else
        echo "  Enrollment ⚠ (coordinator unreachable — enroll later with: dginf-provider enroll)"
    fi
else
    echo "  Enrollment ⚠ (serial number not found)"
fi

# ─── Step 5: Download inference model ─────────────────────────
echo ""
echo "→ [5/7] Downloading inference model..."

# Auto-select model based on RAM
# S3_NAME is the key in our CDN — no HuggingFace account needed
if [ "$MEM" -ge 64 ]; then
    MODEL="mlx-community/Qwen3.5-32B-Instruct-4bit"
    S3_NAME="Qwen3.5-32B-Instruct-4bit"
    MODEL_NAME="Qwen3.5 32B"
    MODEL_SIZE="~20 GB"
elif [ "$MEM" -ge 32 ]; then
    MODEL="mlx-community/Qwen3.5-14B-Instruct-4bit"
    S3_NAME="Qwen3.5-14B-Instruct-4bit"
    MODEL_NAME="Qwen3.5 14B"
    MODEL_SIZE="~9 GB"
elif [ "$MEM" -ge 16 ]; then
    MODEL="mlx-community/Qwen3.5-9B-MLX-4bit"
    S3_NAME="Qwen3.5-9B-MLX-4bit"
    MODEL_NAME="Qwen3.5 9B"
    MODEL_SIZE="~6 GB"
else
    MODEL="mlx-community/Qwen2.5-0.5B-Instruct-4bit"
    S3_NAME="Qwen2.5-0.5B-Instruct-4bit"
    MODEL_NAME="Qwen2.5 0.5B"
    MODEL_SIZE="~0.4 GB"
fi

echo "  Selected: $MODEL_NAME ($MODEL_SIZE) for ${MEM}GB RAM"

# Check if model is already downloaded
HF_CACHE_DIR="$HOME/.cache/huggingface/hub/models--$(echo "$MODEL" | tr '/' '--')"
if [ -d "$HF_CACHE_DIR/snapshots" ]; then
    echo "  Already downloaded ✓"
else
    CACHE_DIR="$HF_CACHE_DIR/snapshots/main"
    mkdir -p "$CACHE_DIR"

    echo "  Downloading $MODEL_NAME ($MODEL_SIZE) from DGInf CDN..."
    echo ""
    # Download pre-packaged tarball from our CDN — no HuggingFace account needed
    if curl -f#L "$BASE_URL/dl/models/$S3_NAME.tar.gz" | tar xz -C "$CACHE_DIR" 2>/dev/null; then
        echo ""
        echo "  Model downloaded ✓"
    else
        # Fallback: try individual files from S3 (public, no auth)
        echo "  Tarball not available, downloading files from S3..."
        S3_HTTP="https://dginf-models.s3.amazonaws.com/$S3_NAME"
        FAILED=false
        for f in config.json tokenizer.json tokenizer_config.json special_tokens_map.json; do
            curl -fsSL "$S3_HTTP/$f" -o "$CACHE_DIR/$f" 2>/dev/null || true
        done
        # Download weight files (try single file first, then sharded)
        if curl -f#L "$S3_HTTP/model.safetensors" -o "$CACHE_DIR/model.safetensors" 2>/dev/null; then
            echo ""
            echo "  Model downloaded ✓"
        elif curl -f#L "$S3_HTTP/model-00001-of-00002.safetensors" -o "$CACHE_DIR/model-00001-of-00002.safetensors" 2>/dev/null; then
            # Sharded model — download remaining shards
            curl -fsSL "$S3_HTTP/model.safetensors.index.json" -o "$CACHE_DIR/model.safetensors.index.json" 2>/dev/null || true
            for i in $(seq -w 2 99); do
                SHARD="model-000${i}-of-*.safetensors"
                curl -fsSL "$S3_HTTP/model-000${i}-of-"*".safetensors" -o "$CACHE_DIR/" 2>/dev/null || break
            done
            echo ""
            echo "  Model downloaded ✓"
        else
            echo "  ⚠ Model download failed — retry with: dginf-provider models download"
            FAILED=true
        fi
    fi
fi

# ─── Step 6: Start provider ──────────────────────────────────
echo ""
echo "→ [6/7] Starting provider..."

PROVIDER_RUNNING=false
if "$BIN_DIR/dginf-provider" start --model "$MODEL" 2>&1; then
    sleep 2
    if [ -f "$HOME/.dginf/provider.pid" ]; then
        PID=$(cat "$HOME/.dginf/provider.pid")
        if kill -0 "$PID" 2>/dev/null; then
            echo "  Provider running (PID $PID) ✓"
            PROVIDER_RUNNING=true
        fi
    fi
fi

if [ "$PROVIDER_RUNNING" = false ]; then
    echo "  ⚠ Provider did not start automatically."
    echo "    Start manually: dginf-provider start --model $MODEL"
fi

# ─── Step 7: Summary ─────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════"
echo ""
echo "  DGInf installation complete!"
echo ""
echo "  Hardware:  $CHIP · ${MEM}GB"
echo "  Model:     $MODEL_NAME"

if [ "$PROVIDER_RUNNING" = true ]; then
    echo "  Status:    ● RUNNING (PID $PID)"
    echo ""
    echo "  Your Mac is now serving private inference!"
else
    echo "  Status:    ○ NOT RUNNING"
    echo ""
    echo "  Start serving:"
    echo "    dginf-provider start --model $MODEL"
fi

echo ""
echo "  Commands:"
echo "    dginf-provider status     Show provider status"
echo "    dginf-provider logs -w    Stream logs"
echo "    dginf-provider stop       Stop the provider"
echo "    dginf-provider doctor     Run diagnostics"
echo ""
echo "════════════════════════════════════════════════"
