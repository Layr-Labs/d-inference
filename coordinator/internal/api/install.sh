#!/bin/bash
# NOTE: This file is also embedded in the coordinator binary via go:embed.
# The copy at coordinator/internal/api/install.sh must be kept in sync.
set -euo pipefail

# Darkbloom Provider Installer
# Usage: curl -fsSL https://api.darkbloom.dev/install.sh | bash
#
# This script:
#   1. Fetches the latest signed release from the coordinator
#   2. Downloads the provider bundle (binary + enclave helper)
#   3. Verifies the bundle hash
#   4. Sets up Python runtime + ffmpeg
#   5. Sets up Secure Enclave identity
#   6. Downloads the best model for your hardware
#   7. Summary with next steps
#
# Zero prerequisites — just macOS + Apple Silicon.

COORD_URL="https://api.darkbloom.dev"
INSTALL_DIR="$HOME/.darkbloom"
BIN_DIR="$INSTALL_DIR/bin"
PYTHON_BIN="$INSTALL_DIR/python/bin/python3.12"
PBS_TAG="20260408"
PBS_PYTHON_VERSION="3.12.13"
PBS_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PBS_TAG}/cpython-${PBS_PYTHON_VERSION}+${PBS_TAG}-aarch64-apple-darwin-install_only.tar.gz"

# Detect if running interactively (terminal) or piped (curl | bash)
if [ -t 0 ]; then
    INTERACTIVE=true
else
    INTERACTIVE=false
fi

echo "╔══════════════════════════════════════════════╗"
echo "║  Darkbloom — Private AI on Verified Macs ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

# ─── Pre-flight checks ───────────────────────────────────────
if [ "$(uname)" != "Darwin" ]; then
    echo "Error: Darkbloom requires macOS with Apple Silicon."
    exit 1
fi
if [ "$(uname -m)" != "arm64" ]; then
    echo "Error: Darkbloom requires Apple Silicon (arm64)."
    exit 1
fi

CHIP=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "Apple Silicon")
MEM=$(sysctl -n hw.memsize 2>/dev/null | awk '{printf "%.0f", $1/1073741824}')
SERIAL=$(ioreg -c IOPlatformExpertDevice -d 2 | awk -F'"' '/IOPlatformSerialNumber/{print $4}')
echo "  $CHIP · ${MEM}GB · macOS $(sw_vers -productVersion)"
echo ""

# ─── Step 1: Fetch latest release ────────────────────────────
echo "→ [1/7] Fetching latest release..."

RELEASE_JSON=$(curl -fsSL "$COORD_URL/v1/releases/latest" 2>/dev/null || echo "")
if [ -z "$RELEASE_JSON" ]; then
    echo "  ✗ Could not reach coordinator at $COORD_URL"
    echo "    Check your internet connection and try again."
    exit 1
fi

# Extract JSON string fields with sed — no python3 needed, avoids Xcode CLT prompt on fresh Macs
json_val() { echo "$1" | sed -n "s/.*\"$2\":\"\([^\"]*\)\".*/\1/p"; }
BUNDLE_URL=$(json_val "$RELEASE_JSON" url)
BUNDLE_HASH=$(json_val "$RELEASE_JSON" bundle_hash)
BINARY_HASH=$(json_val "$RELEASE_JSON" binary_hash)
VERSION=$(json_val "$RELEASE_JSON" version)

echo "  Version: $VERSION"
echo "  Signed by: Developer ID Application: Eigen Labs, Inc."
echo ""

# ─── Step 2: Download and install bundle ──────────────────────
echo "→ [2/7] Downloading Darkbloom v${VERSION}..."
mkdir -p "$INSTALL_DIR" "$BIN_DIR"

curl -f#L "$BUNDLE_URL" -o "/tmp/eigeninference-bundle.tar.gz"

# Verify bundle hash
ACTUAL_HASH=$(shasum -a 256 /tmp/eigeninference-bundle.tar.gz | cut -d' ' -f1)
if [ "$ACTUAL_HASH" != "$BUNDLE_HASH" ]; then
    echo ""
    echo "  ✗ Bundle hash mismatch — download may be corrupted."
    echo "    Expected: $BUNDLE_HASH"
    echo "    Got:      $ACTUAL_HASH"
    rm -f /tmp/eigeninference-bundle.tar.gz
    exit 1
fi
echo ""
echo "  Hash verified ✓"

echo "  Installing binaries..."
tar xzf /tmp/eigeninference-bundle.tar.gz -C "$INSTALL_DIR"

# Migrate older flat bundle layouts into the current install structure.
[ -f "$INSTALL_DIR/darkbloom" ] && mv -f "$INSTALL_DIR/darkbloom" "$BIN_DIR/darkbloom"
[ -f "$INSTALL_DIR/eigeninference-enclave" ] && mv -f "$INSTALL_DIR/eigeninference-enclave" "$BIN_DIR/eigeninference-enclave"
[ -f "$INSTALL_DIR/gRPCServerCLI" ] && mv -f "$INSTALL_DIR/gRPCServerCLI" "$BIN_DIR/gRPCServerCLI"
[ -f "$INSTALL_DIR/ffmpeg" ] && mv -f "$INSTALL_DIR/ffmpeg" "$BIN_DIR/ffmpeg"
[ -f "$INSTALL_DIR/stt_server.py" ] && mv -f "$INSTALL_DIR/stt_server.py" "$BIN_DIR/stt_server.py"
if [ -d "$BIN_DIR/image-bridge" ]; then
    rm -rf "$INSTALL_DIR/image-bridge"
    mv "$BIN_DIR/image-bridge" "$INSTALL_DIR/image-bridge"
fi

chmod +x "$BIN_DIR/darkbloom" "$BIN_DIR/eigeninference-enclave" "$BIN_DIR/gRPCServerCLI" "$BIN_DIR/ffmpeg" "$BIN_DIR/stt_server.py" 2>/dev/null || true
rm -f /tmp/eigeninference-bundle.tar.gz

# Verify image pipeline components
if [ -f "$BIN_DIR/gRPCServerCLI" ]; then
    echo "  gRPCServerCLI ✓"
else
    echo "  ⚠ gRPCServerCLI not found — image generation unavailable"
fi
if [ -d "$INSTALL_DIR/image-bridge/eigeninference_image_bridge" ]; then
    echo "  Image bridge ✓"
else
    echo "  ⚠ Image bridge not found — image generation unavailable"
fi

# Verify code signature (codesign is part of base macOS, no CLT needed)
if codesign --verify --verbose "$BIN_DIR/darkbloom" 2>/dev/null; then
    TEAM=$(codesign -dvv "$BIN_DIR/darkbloom" 2>&1 | grep "TeamIdentifier=" | cut -d= -f2)
    echo "  Code signature verified ✓ (Team: $TEAM)"
else
    echo "  ⚠ Code signature could not be verified"
fi

# Make available in PATH
# Try /usr/local/bin symlink first (may need sudo on newer macOS)
SYMLINKED=false
if ln -sf "$BIN_DIR/darkbloom" /usr/local/bin/darkbloom 2>/dev/null; then
    SYMLINKED=true
fi

# Always add to shell rc so it works even without the symlink
RC="$HOME/.zshrc"
if [ -f "$HOME/.bashrc" ] && [ ! -f "$HOME/.zshrc" ]; then
    RC="$HOME/.bashrc"
fi
if ! grep -q "\.darkbloom/bin" "$RC" 2>/dev/null; then
    # Remove old PATH entries from previous installs
    sed -i '' '/\.dginf\/bin/d; /\.eigeninference\/bin/d; /alias eigeninf/d; /alias dginf/d; /# EigenInference/d; /# Darkbloom$/d' "$RC" 2>/dev/null || true
    cat >> "$RC" << 'SHELL'

# Darkbloom
export PATH="$HOME/.darkbloom/bin:$PATH"
SHELL
fi
export PATH="$BIN_DIR:$PATH"

# Source the rc file so commands are available immediately in this session
# (important when running via curl | bash — the parent shell won't have PATH yet)
# Temporarily disable -eu: the user's rc file may reference unbound variables
# or use zsh-specific builtins that fail in bash, and set -u causes an immediate
# exit that || true cannot catch.
set +eu; source "$RC" 2>/dev/null; set -eu

echo "  Binaries installed ✓"
echo "  Shortcut: darkbloom"

# ─── Migrate from old installs ───────────────────────────────
# Migration chain: ~/.dginf → ~/.eigeninference → ~/.darkbloom
for OLD_DIR in "$HOME/.dginf" "$HOME/.eigeninference"; do
    if [ -d "$OLD_DIR" ] && [ ! -L "$OLD_DIR" ]; then
        echo ""
        echo "  Migrating from $OLD_DIR..."
        for f in enclave_key.data wallet_key; do
            [ -f "$OLD_DIR/$f" ] && cp -n "$OLD_DIR/$f" "$INSTALL_DIR/$f" 2>/dev/null || true
        done
        if [ -d "$OLD_DIR/python" ] && [ ! -d "$INSTALL_DIR/python" ]; then
            ln -sf "$OLD_DIR/python" "$INSTALL_DIR/python"
        fi
        if [ -f "$OLD_DIR/ffmpeg" ] && [ ! -f "$INSTALL_DIR/ffmpeg" ]; then
            ln -sf "$OLD_DIR/ffmpeg" "$INSTALL_DIR/ffmpeg"
        fi
        # Symlink old path so stragglers still work
        ln -sfn "$INSTALL_DIR" "$OLD_DIR" 2>/dev/null || true
        echo "  Migration complete ✓"
    fi
done

# ─── Step 3: Python runtime + ffmpeg ─────────────────────────
echo ""
echo "→ [3/7] Verifying inference runtime..."

# Check for Python runtime
if [ -f "$PYTHON_BIN" ] && "$PYTHON_BIN" -c "import vllm_mlx" 2>/dev/null; then
    echo "  Python runtime ✓"
else
    echo "  Downloading Python runtime (~105 MB)..."
    if curl -f#L "$COORD_URL/dl/eigeninference-python-runtime.tar.gz" -o "/tmp/eigeninference-python.tar.gz" 2>/dev/null; then
        rm -rf "$INSTALL_DIR/python"
        tar xzf /tmp/eigeninference-python.tar.gz -C "$INSTALL_DIR"
        rm -f /tmp/eigeninference-python.tar.gz
        echo ""
        echo "  Python runtime installed ✓"
    else
        # Fallback to old URL
        if curl -f#L "$COORD_URL/dl/dginf-python-runtime.tar.gz" -o "/tmp/eigeninference-python.tar.gz" 2>/dev/null; then
            rm -rf "$INSTALL_DIR/python"
            tar xzf /tmp/eigeninference-python.tar.gz -C "$INSTALL_DIR"
            rm -f /tmp/eigeninference-python.tar.gz
            echo ""
            echo "  Python runtime installed ✓"
        else
            echo "  ⚠ Python runtime download failed — inference won't work without it"
        fi
    fi
fi

# Test that extracted Python actually runs (catches dyld errors from non-portable builds)
if ! { [ -f "$PYTHON_BIN" ] && "$PYTHON_BIN" -c "print('ok')" 2>/dev/null; }; then
    echo "  ⚠ Python runtime missing or broken"
    echo "  Downloading portable Python from python-build-standalone..."
    if curl -f#L "$PBS_URL" -o "/tmp/pbs-python.tar.gz" 2>/dev/null; then
        rm -rf "$INSTALL_DIR/python"
        mkdir -p "$INSTALL_DIR/python"
        tar xzf /tmp/pbs-python.tar.gz --strip-components=1 -C "$INSTALL_DIR/python"
        rm -f /tmp/pbs-python.tar.gz
        rm -f "$INSTALL_DIR/python/lib/python3.12/EXTERNALLY-MANAGED"
        if "$PYTHON_BIN" -c "print('ok')" 2>/dev/null; then
            echo "  Portable Python installed ✓"
            # Install packages from R2 site-packages tarball (same verified artifacts as CI)
            SITE_DIR="$INSTALL_DIR/python/lib/python3.12/site-packages"
            R2_CDN="https://pub-3d1cb668259340eeb2276e1d375c846d.r2.dev"
            if [ -n "$VERSION" ] && curl -fsSL "$R2_CDN/releases/v${VERSION}/eigeninference-site-packages.tar.gz" -o "/tmp/eigen-site-packages.tar.gz" 2>/dev/null; then
                rm -rf "$SITE_DIR"
                mkdir -p "$SITE_DIR"
                tar xzf /tmp/eigen-site-packages.tar.gz -C "$SITE_DIR"
                rm -f /tmp/eigen-site-packages.tar.gz
                echo "  Packages installed from R2 ✓"
            else
                # Fallback: pip install from GitHub
                "$PYTHON_BIN" -m pip install --quiet "https://github.com/Gajesh2007/vllm-mlx/archive/refs/heads/main.zip" mlx-lm 2>/dev/null || true
            fi
        else
            echo "  ✗ Portable Python also failed — please report this issue"
        fi
    else
        echo "  ✗ Could not download portable Python"
    fi
fi

# Verify vllm-mlx
if [ -f "$PYTHON_BIN" ]; then
    if ! "$PYTHON_BIN" -c "print('ok')" 2>/dev/null; then
        echo "  ✗ Python binary does not execute"
    else
        PYTHONHOME="$INSTALL_DIR/python" "$PYTHON_BIN" -c \
            "import vllm_mlx; print(f'  vllm-mlx {vllm_mlx.__version__} ✓')" 2>/dev/null \
            || echo "  ⚠ vllm-mlx import failed"
    fi
fi

# Ensure ffmpeg is available (bundled since v0.3.4, fallback download for older installs)
if [ -x "$BIN_DIR/ffmpeg" ]; then
    echo "  ffmpeg ✓ (bundled)"
elif command -v ffmpeg &>/dev/null; then
    echo "  ffmpeg ✓ (system)"
elif [ -x "$INSTALL_DIR/ffmpeg" ]; then
    echo "  ffmpeg ✓"
else
    echo "  Downloading ffmpeg..."
    if curl -fsSL "$COORD_URL/dl/ffmpeg-macos-arm64" -o "$BIN_DIR/ffmpeg" 2>/dev/null; then
        chmod +x "$BIN_DIR/ffmpeg"
        echo "  ffmpeg ✓"
    else
        echo "  ffmpeg ⚠ (optional — needed only for speech-to-text)"
    fi
fi

# ─── Step 4: Secure Enclave identity ─────────────────────────
echo ""
echo "→ [4/7] Setting up Secure Enclave identity..."

"$BIN_DIR/eigeninference-enclave" info >/dev/null 2>&1 \
    && echo "  Secure Enclave ✓ (P-256 key generated)" \
    || echo "  Secure Enclave ⚠ (not available on this hardware)"

# ─── Step 5: Enrollment + device attestation ─────────────────
echo ""
echo "→ [5/7] Enrollment + device attestation..."

ALREADY_ENROLLED=false
if profiles status -type enrollment 2>&1 | grep -q "MDM enrollment: Yes"; then
    ALREADY_ENROLLED=true
fi

if [ "$ALREADY_ENROLLED" = true ]; then
    echo "  Already enrolled ✓"
elif [ -n "$SERIAL" ]; then
    echo "  Requesting enrollment profile..."
    rm -f "/tmp/EigenInference-Enroll-${SERIAL}.mobileconfig" 2>/dev/null
    if curl -fsSL -X POST "$COORD_URL/v1/enroll" \
        -H "Content-Type: application/json" \
        -d "{\"serial_number\": \"$SERIAL\"}" \
        -o "/tmp/EigenInference-Enroll-${SERIAL}.mobileconfig" 2>/dev/null; then
        echo ""
        echo "  ┌──────────────────────────────────────────────────┐"
        echo "  │ ACTION REQUIRED: Install the enrollment profile   │"
        echo "  │                                                   │"
        echo "  │ This profile will:                                │"
        echo "  │  • Verify SIP, Secure Boot, system integrity      │"
        echo "  │  • Generate a key in your Secure Enclave          │"
        echo "  │  • Apple verifies your device is genuine          │"
        echo "  │                                                   │"
        echo "  │ Darkbloom CANNOT erase, lock, or control     │"
        echo "  │ your Mac. Remove anytime in System Settings.      │"
        echo "  └──────────────────────────────────────────────────┘"
        echo ""
        # Register the profile, then open System Settings to the install pane
        open "/tmp/EigenInference-Enroll-${SERIAL}.mobileconfig"
        sleep 1
        open "x-apple.systempreferences:com.apple.Profiles-Settings.extension"

        echo "  System Settings opened — click Install and enter your password."
        echo ""
        if [ "$INTERACTIVE" = true ]; then
            read -p "  Press Enter after installing the profile..."
        else
            echo "  Install the profile, then the provider will verify on start."
            sleep 3
        fi
        echo "  Enrollment ✓"
    else
        echo "  Enrollment ⚠ (coordinator unreachable — enroll later with: darkbloom enroll)"
    fi
else
    echo "  Enrollment ⚠ (serial number not found)"
fi

# ─── Step 6: Download inference model ─────────────────────────
echo ""
echo "→ [6/7] Selecting inference model..."

MODEL=""
S3_NAME=""
MODEL_NAME=""
MODEL_SIZE=""
IMAGE_MODEL=""

# Fetch model catalog from coordinator
CATALOG_JSON=$(curl -fsSL "$COORD_URL/v1/models/catalog" 2>/dev/null || echo "")

# Use bundled Python (installed in step 3) for catalog parsing — system python3 may not exist
CATALOG_PYTHON="$PYTHON_BIN"
[ ! -f "$CATALOG_PYTHON" ] && CATALOG_PYTHON="python3"

if [ -n "$CATALOG_JSON" ] && echo "$CATALOG_JSON" | PYTHONHOME="$INSTALL_DIR/python" "$CATALOG_PYTHON" -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
    AVAILABLE_MODELS=$(echo "$CATALOG_JSON" | PYTHONHOME="$INSTALL_DIR/python" "$CATALOG_PYTHON" -c "
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
                else
                    echo "  Invalid selection."
                fi
            else
                echo "  Skipped — download models later: darkbloom models download"
            fi
        else
            echo "  Run interactively to select: curl -fsSL $COORD_URL/install.sh | bash -s"
        fi
    else
        echo "  No models in catalog for ${MEM}GB RAM"
    fi
fi

# Download selected model
if [ -n "$MODEL" ]; then
    HF_CACHE_DIR="$HOME/.cache/huggingface/hub/models--$(echo "$MODEL" | tr '/' '--')"
    if [ -d "$HF_CACHE_DIR/snapshots" ]; then
        echo "  $MODEL_NAME already downloaded ✓"
    else
        CACHE_DIR="$HF_CACHE_DIR/snapshots/main"
        mkdir -p "$CACHE_DIR"
        echo "  Downloading $MODEL_NAME ($MODEL_SIZE)..."
        echo ""

        # Try CDN tarball first, then individual files from R2
        if curl -f#L "$COORD_URL/dl/models/$S3_NAME.tar.gz" | tar xz -C "$CACHE_DIR" 2>/dev/null; then
            echo ""
            echo "  $MODEL_NAME downloaded ✓"
        else
            echo "  Tarball not available, downloading from R2..."
            R2_BASE="https://pub-7cbee059c80c46ec9c071dbee2726f8a.r2.dev/$S3_NAME"
            for f in config.json tokenizer.json tokenizer_config.json special_tokens_map.json model.safetensors.index.json; do
                curl -fsSL "$R2_BASE/$f" -o "$CACHE_DIR/$f" 2>/dev/null || true
            done
            # Download weight shards
            for f in $(curl -fsSL "$R2_BASE/" 2>/dev/null | grep -o 'model-[0-9]*-of-[0-9]*.safetensors' || echo "model.safetensors"); do
                echo "  Downloading $f..."
                curl -f#L "$R2_BASE/$f" -o "$CACHE_DIR/$f" 2>/dev/null || true
            done
            echo "  $MODEL_NAME downloaded ✓"
        fi
    fi
fi

# ─── Step 7: Summary ─────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════"
echo ""
echo "  Darkbloom v${VERSION} installed!"
echo ""
echo "  Hardware:  $CHIP · ${MEM}GB"
if [ -n "$MODEL_NAME" ]; then
    echo "  Model:     $MODEL_NAME"
fi
echo "  Binary:    Signed + notarized by Eigen Labs, Inc."
echo "  Status:    ○ Installed (not running)"
echo ""
echo "  Start serving:"
if [ -n "$MODEL" ]; then
    echo "    darkbloom serve --model $MODEL"
else
    echo "    darkbloom serve"
fi
echo ""

if [ ! -f "$HOME/.config/eigeninference/auth_token" ]; then
    echo "  ┌──────────────────────────────────────────────┐"
    echo "  │  Link your account to earn rewards:          │"
    echo "  │                                              │"
    echo "  │    darkbloom login              │"
    echo "  │                                              │"
    echo "  │  Without linking, earnings go to a local     │"
    echo "  │  wallet and cannot be withdrawn.             │"
    echo "  └──────────────────────────────────────────────┘"
    echo ""
fi

echo "  Commands:"
echo "    darkbloom serve       Start serving"
echo "    darkbloom status      Show status"
echo "    darkbloom logs -w     Stream logs"
echo "    darkbloom stop        Stop provider"
echo "    darkbloom update      Check for updates"
echo "    darkbloom doctor      Run diagnostics"
echo ""
echo "  Open a new terminal or run: source ~/.zshrc"
echo ""
echo "════════════════════════════════════════════════"
