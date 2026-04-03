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
#   6. Installs the DGInf menu bar app (from coordinator)
#   7. Starts the provider in the background
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
echo "→ [1/8] Downloading DGInf..."
mkdir -p "$DGINF_DIR" "$BIN_DIR"
curl -f#L "$BASE_URL/dl/dginf-bundle-macos-arm64.tar.gz" -o "/tmp/dginf-bundle.tar.gz"

echo "  Installing binaries..."
tar xzf /tmp/dginf-bundle.tar.gz -C "$DGINF_DIR"
mv "$DGINF_DIR/dginf-provider" "$BIN_DIR/" 2>/dev/null || true
mv "$DGINF_DIR/dginf-enclave" "$BIN_DIR/" 2>/dev/null || true
mv "$DGINF_DIR/gRPCServerCLI-macOS" "$BIN_DIR/" 2>/dev/null || true
chmod +x "$BIN_DIR/dginf-provider" "$BIN_DIR/dginf-enclave" 2>/dev/null || true
chmod +x "$BIN_DIR/gRPCServerCLI-macOS" 2>/dev/null || true
rm -f /tmp/dginf-bundle.tar.gz

# Download bundled Python runtime (self-contained: Python 3.12 + vllm-mlx + mlx + mlx_lm).
# This is a complete, standalone Python — no system Python or pip needed.
if [ -f "$PYTHON_BIN" ] && "$PYTHON_BIN" -c "import vllm_mlx" 2>/dev/null; then
    echo "  Python runtime already installed ✓"
else
    echo "  Downloading Python runtime (~105 MB)..."
    curl -f#L "$BASE_URL/dl/dginf-python-runtime.tar.gz" -o "/tmp/dginf-python.tar.gz"
    # Remove any existing broken/symlinked Python install
    rm -rf "$DGINF_DIR/python"
    tar xzf /tmp/dginf-python.tar.gz -C "$DGINF_DIR"
    rm -f /tmp/dginf-python.tar.gz
    echo "  Python runtime installed ✓"
fi

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
echo "→ [2/8] Verifying inference runtime..."

# Verify bundled Python + vllm-mlx
if [ -f "$PYTHON_BIN" ]; then
    PYTHONHOME="$DGINF_DIR/python" "$PYTHON_BIN" -c \
        "import vllm_mlx; print(f'  vllm-mlx {vllm_mlx.__version__} ✓')" 2>/dev/null \
        || echo "  ⚠ vllm-mlx import failed — inference may fall back to mlx_lm"
else
    echo "  ✗ Bundled Python not found — inference will not work"
    echo "    Reinstall: curl -fsSL $BASE_URL/install.sh | bash"
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
echo "→ [3/8] Setting up Secure Enclave identity..."
rm -f "$DGINF_DIR/enclave_key.data" 2>/dev/null
"$BIN_DIR/dginf-enclave" info >/dev/null 2>&1 \
    && echo "  Secure Enclave ✓ (P-256 key generated)" \
    || echo "  Secure Enclave ⚠ (not available on this hardware)"

# ─── Step 4: Enrollment + device attestation ─────────────────
echo ""
echo "→ [4/8] Enrollment + device attestation..."

# Check if already enrolled before prompting.
# `profiles list` only shows user-level profiles — MDM is device-level.
# `profiles status -type enrollment` reliably reports MDM without sudo.
ALREADY_ENROLLED=false
if profiles status -type enrollment 2>&1 | grep -q "MDM enrollment: Yes"; then
    ALREADY_ENROLLED=true
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
echo "→ [5/8] Downloading inference model..."

# Initialize model variables (set -u requires all vars to be defined before use)
MODEL=""
S3_NAME=""
MODEL_NAME=""
MODEL_SIZE=""
MODEL_TYPE=""
IMAGE_MODEL=""
IMAGE_S3_NAME=""
IMAGE_MODEL_NAME=""
IMAGE_MODEL_SIZE=""

# Fetch model catalog from coordinator. The user picks which model to serve.
CATALOG_JSON=$(curl -fsSL "$BASE_URL/v1/models/catalog" 2>/dev/null || echo "")

if [ -n "$CATALOG_JSON" ] && echo "$CATALOG_JSON" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
    # Show available models and let the user pick
    AVAILABLE_MODELS=$(echo "$CATALOG_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
mem = int(sys.argv[1])
idx = 1
for m in data.get('models', []):
    if m.get('min_ram_gb', 999) > mem:
        continue
    name = m.get('display_name', m['id'])
    size = m.get('size_gb', '?')
    mtype = m.get('model_type', 'text')
    print(f'{idx}. {name} (~{size} GB) [{mtype}]')
    print(f'   {m[\"id\"]}|{m.get(\"s3_name\", m[\"id\"].split(\"/\")[-1])}|{name}|{size}|{mtype}')
    idx += 1
" "$MEM" 2>/dev/null)

    if [ -n "$AVAILABLE_MODELS" ]; then
        echo ""
        echo "  Available models for your hardware (${MEM}GB RAM):"
        echo ""
        echo "$AVAILABLE_MODELS" | grep -v "^   " | sed 's/^/  /'
        echo ""

        if [ "$INTERACTIVE" = true ]; then
            read -p "  Select a model number (or press Enter to skip): " MODEL_CHOICE
            if [ -n "$MODEL_CHOICE" ]; then
                MODEL_LINE=$(echo "$AVAILABLE_MODELS" | grep "^   " | sed -n "${MODEL_CHOICE}p" | sed 's/^   //')
                if [ -n "$MODEL_LINE" ]; then
                    MODEL=$(echo "$MODEL_LINE" | cut -d'|' -f1)
                    S3_NAME=$(echo "$MODEL_LINE" | cut -d'|' -f2)
                    MODEL_NAME=$(echo "$MODEL_LINE" | cut -d'|' -f3)
                    MODEL_SIZE="~$(echo "$MODEL_LINE" | cut -d'|' -f4) GB"
                    MODEL_TYPE=$(echo "$MODEL_LINE" | cut -d'|' -f5)
                else
                    echo "  Invalid selection."
                fi
            else
                echo "  Skipped model selection."
                echo "  You can download models later: dginf-provider models download"
            fi
        else
            echo "  Run interactively to select a model:"
            echo "    curl -fsSL $BASE_URL/install.sh | bash -s"
            echo "  Or download later: dginf-provider models download"
        fi
    fi
fi

# Fallback only if catalog fetch failed entirely (network error) AND interactive.
if [ -z "$MODEL" ] && [ -z "$CATALOG_JSON" ] && [ "$INTERACTIVE" = true ]; then
    echo "  Catalog unavailable. Select a default model?"
    if [ "$MEM" -ge 36 ]; then
        read -p "  Download Qwen3.5 27B (~27 GB)? [y/N]: " DL_DEFAULT
        if [ "$DL_DEFAULT" = "y" ] || [ "$DL_DEFAULT" = "Y" ]; then
            MODEL="qwen3.5-27b-claude-opus-8bit"
            S3_NAME="qwen35-27b-claude-opus-8bit"
            MODEL_NAME="Qwen3.5 27B Claude Opus Distilled"
            MODEL_SIZE="~27 GB"
        fi
    fi
fi

if [ -n "$MODEL" ]; then
    echo "  Text:     $MODEL_NAME ($MODEL_SIZE)"
fi
if [ -n "$IMAGE_MODEL" ]; then
    echo "  Image:    $IMAGE_MODEL_NAME ($IMAGE_MODEL_SIZE)"
fi
if [ -z "$MODEL" ] && [ -z "$IMAGE_MODEL" ]; then
    echo "  No models in catalog for ${MEM}GB RAM"
fi

# --- Download primary model ---
download_model() {
    local model_id="$1" s3_name="$2" model_name="$3" model_size="$4"
    local hf_cache_dir="$HOME/.cache/huggingface/hub/models--$(echo "$model_id" | tr '/' '--')"

    if [ -d "$hf_cache_dir/snapshots" ]; then
        echo "  $model_name already downloaded ✓"
        return 0
    fi

    local cache_dir="$hf_cache_dir/snapshots/main"
    mkdir -p "$cache_dir"

    echo "  Downloading $model_name ($model_size) from DGInf CDN..."
    echo ""
    if curl -f#L "$BASE_URL/dl/models/$s3_name.tar.gz" | tar xz -C "$cache_dir" 2>/dev/null; then
        echo ""
        echo "  $model_name downloaded ✓"
        return 0
    fi

    # Fallback: try individual files from R2 (public, no auth, zero egress)
    echo "  Tarball not available, downloading files from R2..."
    local s3_http="https://9e92221750c162ade0f2730f63f4963d.r2.cloudflarestorage.com/d-inf-models/$s3_name"
    for f in config.json tokenizer.json tokenizer_config.json special_tokens_map.json; do
        curl -fsSL "$s3_http/$f" -o "$cache_dir/$f" 2>/dev/null || true
    done
    if curl -f#L "$s3_http/model.safetensors" -o "$cache_dir/model.safetensors" 2>/dev/null; then
        echo ""
        echo "  $model_name downloaded ✓"
    elif curl -f#L "$s3_http/model-00001-of-00002.safetensors" -o "$cache_dir/model-00001-of-00002.safetensors" 2>/dev/null; then
        curl -fsSL "$s3_http/model.safetensors.index.json" -o "$cache_dir/model.safetensors.index.json" 2>/dev/null || true
        for i in $(seq -w 2 99); do
            curl -fsSL "$s3_http/model-000${i}-of-"*".safetensors" -o "$cache_dir/" 2>/dev/null || break
        done
        echo ""
        echo "  $model_name downloaded ✓"
    else
        echo "  ⚠ $model_name download failed — retry with: dginf-provider models download"
        return 1
    fi
}

if [ -n "$MODEL" ]; then
    download_model "$MODEL" "$S3_NAME" "$MODEL_NAME" "$MODEL_SIZE" || true
fi

# --- Download image model + backend (if selected) ---
IMAGE_MODEL_PATH=""
if [ -n "$IMAGE_MODEL" ]; then
    echo ""
    echo "  Setting up image generation..."

    # gRPCServerCLI is bundled in the provider tarball (extracted in step 1)
    if [ -x "$BIN_DIR/gRPCServerCLI-macOS" ]; then
        echo "  gRPCServerCLI ✓ (bundled)"
    else
        echo "  ⚠ gRPCServerCLI not found in bundle — image generation won't be available"
        IMAGE_MODEL=""
    fi

    # Download image-bridge Python package
    if [ -n "$IMAGE_MODEL" ]; then
        if [ ! -d "$DGINF_DIR/image-bridge/dginf_image_bridge" ]; then
            echo "  Downloading image bridge..."
            if curl -f#L "$BASE_URL/dl/dginf-image-bridge.tar.gz" -o "/tmp/dginf-image-bridge.tar.gz" 2>/dev/null; then
                mkdir -p "$DGINF_DIR/image-bridge"
                tar xzf /tmp/dginf-image-bridge.tar.gz -C "$DGINF_DIR/image-bridge"
                rm -f /tmp/dginf-image-bridge.tar.gz
                echo "  Image bridge ✓"
            else
                echo "  ⚠ Image bridge download failed — image generation won't be available"
                IMAGE_MODEL=""
            fi
        else
            echo "  Image bridge already installed ✓"
        fi
    fi

    # Download image model weights
    if [ -n "$IMAGE_MODEL" ]; then
        IMAGE_MODEL_DIR="$DGINF_DIR/models/$IMAGE_S3_NAME"
        if [ -d "$IMAGE_MODEL_DIR" ]; then
            echo "  $IMAGE_MODEL_NAME already downloaded ✓"
            IMAGE_MODEL_PATH="$IMAGE_MODEL_DIR"
        else
            mkdir -p "$IMAGE_MODEL_DIR"
            echo "  Downloading $IMAGE_MODEL_NAME ($IMAGE_MODEL_SIZE)..."
            if curl -f#L "$BASE_URL/dl/models/$IMAGE_S3_NAME.tar.gz" | tar xz -C "$IMAGE_MODEL_DIR" 2>/dev/null; then
                echo ""
                echo "  $IMAGE_MODEL_NAME downloaded ✓"
                IMAGE_MODEL_PATH="$IMAGE_MODEL_DIR"
            else
                # Fallback: try R2
                S3_HTTP="https://9e92221750c162ade0f2730f63f4963d.r2.cloudflarestorage.com/d-inf-models/$IMAGE_S3_NAME"
                if curl -f#L "$S3_HTTP/$IMAGE_MODEL.ckpt" -o "$IMAGE_MODEL_DIR/$IMAGE_MODEL.ckpt" 2>/dev/null; then
                    echo ""
                    echo "  $IMAGE_MODEL_NAME downloaded ✓"
                    IMAGE_MODEL_PATH="$IMAGE_MODEL_DIR"
                else
                    echo "  ⚠ Image model download failed — image generation won't be available"
                    IMAGE_MODEL=""
                fi
            fi
        fi
    fi
fi

# ─── Step 6: Install DGInf menu bar app ───────────────────────
echo ""
echo "→ [6/8] Installing DGInf app..."

APP_INSTALLED=false
APP_PATH="/Applications/DGInf.app"
DMG_URL="$BASE_URL/dl/DGInf-latest.dmg"
DMG_TMP="/tmp/DGInf-latest.dmg"

if curl -f#L "$DMG_URL" -o "$DMG_TMP" 2>/dev/null; then
    echo ""
    # Mount DMG and find the volume path from hdiutil output
    MOUNT_POINT=$(hdiutil attach "$DMG_TMP" -nobrowse 2>/dev/null | grep "/Volumes/" | sed 's/.*\(\/Volumes\/.*\)/\1/' | head -1)
    if [ -n "$MOUNT_POINT" ] && [ -d "$MOUNT_POINT/DGInf.app" ]; then
        rm -rf "$APP_PATH" 2>/dev/null || true
        cp -R "$MOUNT_POINT/DGInf.app" "$APP_PATH" 2>/dev/null || \
            cp -R "$MOUNT_POINT/DGInf.app" "$HOME/Applications/DGInf.app" 2>/dev/null || true
        hdiutil detach "$MOUNT_POINT" 2>/dev/null || true
        if [ -d "$APP_PATH" ] || [ -d "$HOME/Applications/DGInf.app" ]; then
            echo "  DGInf.app installed ✓"
            APP_INSTALLED=true
        fi
    else
        hdiutil detach "$MOUNT_POINT" 2>/dev/null || true
        echo "  ⚠ Could not mount DMG"
    fi
    rm -f "$DMG_TMP"
else
    # DMG not available — keep existing app if present
    if [ -d "$APP_PATH" ]; then
        echo "  DGInf.app (existing) ✓"
        APP_INSTALLED=true
    else
        echo "  ⚠ App not available yet — use CLI for now"
    fi
fi

# ─── Step 7: Ready to serve ──────────────────────────────────
echo ""
echo "→ [7/8] Installation complete."
echo ""
echo "  The provider is NOT started automatically."
echo "  You control when your GPU is used for inference."
PROVIDER_RUNNING=false

# ─── Step 8: Summary ─────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════"
echo ""
echo "  DGInf installation complete!"
echo ""
echo "  Hardware:  $CHIP · ${MEM}GB"
echo "  Model:     $MODEL_NAME"
if [ -n "$IMAGE_MODEL" ]; then
    echo "  Image:     $IMAGE_MODEL_NAME"
fi

echo "  Status:    ○ INSTALLED (not running)"
echo ""
echo "  Start serving when you're ready:"
if [ -n "$MODEL" ]; then
    echo "    dginf-provider start --model $MODEL"
else
    echo "    dginf-provider start"
fi

if [ "$APP_INSTALLED" = true ]; then
    echo ""
    echo "  Menu Bar App: DGInf.app installed"
    echo "    Launch from Spotlight or: open -a DGInf"
fi

if [ ! -f "$HOME/.config/dginf/auth_token" ]; then
    echo ""
    echo "  ┌──────────────────────────────────────────┐"
    echo "  │  Link to your account to earn rewards:   │"
    echo "  │                                          │"
    echo "  │    dginf-provider login                  │"
    echo "  │                                          │"
    echo "  │  Without linking, earnings go to a local │"
    echo "  │  wallet and cannot be withdrawn.         │"
    echo "  └──────────────────────────────────────────┘"
fi

echo ""
echo "  Commands:"
echo "    dginf-provider login      Link to your account"
echo "    dginf-provider status     Show provider status"
echo "    dginf-provider logs -w    Stream logs"
echo "    dginf-provider stop       Stop the provider"
echo "    dginf-provider doctor     Run diagnostics"
echo ""
echo "  App:"
echo "    open -a DGInf             Launch menu bar app"
echo ""
echo "════════════════════════════════════════════════"
