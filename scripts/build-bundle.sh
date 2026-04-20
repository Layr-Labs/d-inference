#!/bin/bash
set -euo pipefail

# Build the EigenInference provider bundle tarball
#
# Creates a self-contained tarball with:
#   darkbloom     Rust CLI binary (no Python linking)
#   eigeninference-enclave      Swift Secure Enclave CLI
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
#   - SSH key at ~/.ssh/eigeninference-infra (for --upload)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUNDLE_DIR="/tmp/eigeninference-bundle"
TARBALL="/tmp/eigeninference-bundle-macos-arm64.tar.gz"
PBS_TAG="20260408"
PBS_PYTHON_VERSION="3.12.13"
PBS_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PBS_TAG}/cpython-${PBS_PYTHON_VERSION}+${PBS_TAG}-aarch64-apple-darwin-install_only.tar.gz"

UPLOAD=false
SKIP_BUILD=false
for arg in "$@"; do
    case "$arg" in
        --upload) UPLOAD=true ;;
        --skip-build) SKIP_BUILD=true ;;
    esac
done

echo "╔══════════════════════════════════════════════════╗"
echo "║  EigenInference Bundle Builder                            ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""

# ─── 1. Build Rust provider ──────────────────────────────────
if [ "$SKIP_BUILD" = false ]; then
    echo "1. Preparing portable Python runtime for Rust build..."
    echo "   darkbloom build is deferred until the portable runtime is ready"
    echo ""
else
    echo "1. Skipping Rust build (--skip-build)"
    echo ""
fi

# ─── 2. Build Swift enclave CLI ───────────────────────────────
if [ "$SKIP_BUILD" = false ]; then
    echo "2. Building eigeninference-enclave (Swift)..."
    cd "$PROJECT_DIR/enclave"
    swift build -c release 2>&1 | tail -3
    echo "   ✓ eigeninference-enclave ($(du -h .build/release/eigeninference-enclave | cut -f1))"
    echo ""
else
    echo "2. Skipping Swift build (--skip-build)"
    echo ""
fi

ENCLAVE_BIN="$PROJECT_DIR/enclave/.build/release/eigeninference-enclave"
if [ ! -f "$ENCLAVE_BIN" ]; then
    echo "   WARNING: eigeninference-enclave not found. Attestation will be unavailable."
fi

# ─── 3. Create portable Python 3.12 runtime with inference deps ──────────
echo "3. Creating portable Python runtime with inference deps..."
rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR"

echo "   Downloading python-build-standalone ${PBS_PYTHON_VERSION}..."
curl -fsSL "$PBS_URL" -o /tmp/eigeninference-python.tar.gz
mkdir -p "$BUNDLE_DIR/python"
tar xzf /tmp/eigeninference-python.tar.gz --strip-components=1 -C "$BUNDLE_DIR/python"
rm -f /tmp/eigeninference-python.tar.gz

PYTHON312="$BUNDLE_DIR/python/bin/python3.12"
echo "   Using $PYTHON312 ($("$PYTHON312" --version))"
"$PYTHON312" -m pip install --quiet --upgrade pip

echo "   Installing vllm-mlx and dependencies..."
"$PYTHON312" -m pip install --quiet --no-cache-dir \
  'mlx-lm>=0.31.2' \
  'git+https://github.com/Gajesh2007/vllm-mlx.git@main' \
  grpcio flatbuffers Pillow mlx-audio tokenizers
# Force-upgrade mlx-lm in case a transitive dep pinned an older version
"$PYTHON312" -m pip install --quiet --no-cache-dir --upgrade 'mlx-lm>=0.31.2'

echo "   Stripping unnecessary packages (keeping pip)..."
cd "$BUNDLE_DIR/python/lib/python3.12/site-packages"
rm -rf torch* gradio* opencv* cv2* pandas* pyarrow* \
       sympy* networkx* mcp* miniaudio* pydub* datasets*
find "$BUNDLE_DIR/python" -name __pycache__ -type d -exec rm -rf {} + 2>/dev/null || true
# Remove EXTERNALLY-MANAGED so pip works without --break-system-packages
rm -f "$BUNDLE_DIR/python/lib/python3.12/EXTERNALLY-MANAGED"

echo "   Code-signing portable Python runtime..."
find "$BUNDLE_DIR/python" -type f | while read -r file; do
    if file "$file" | grep -q "Mach-O"; then
        codesign --force --sign - --options runtime "$file"
    fi
done

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

# Verify vllm-mlx can actually import (catches dependency version mismatches)
echo "   Verifying vllm-mlx imports..."
if "$BUNDLE_DIR/python/bin/python3.12" -c "from vllm_mlx.server import app; print('     ✓ vllm-mlx server imports OK')"; then
    :
else
    echo "   ERROR: vllm-mlx failed to import — dependency version mismatch?"
    echo "   Check mlx-lm version: $("$BUNDLE_DIR/python/bin/python3.12" -c "import mlx_lm; print(mlx_lm.__version__)" 2>/dev/null || echo "unknown")"
    exit 1
fi
echo ""

# ─── 3.5. Build Rust provider against portable Python ────────
if [ "$SKIP_BUILD" = false ]; then
    echo "3.5. Building darkbloom against portable Python..."
    cd "$PROJECT_DIR/provider"
    LIB_DIR="$BUNDLE_DIR/python/lib"
    PYO3_PYTHON="$PYTHON312" \
    PYO3_USE_ABI3_FORWARD_COMPATIBILITY=1 \
    LIBRARY_PATH="$LIB_DIR${LIBRARY_PATH:+:$LIBRARY_PATH}" \
    DYLD_LIBRARY_PATH="$LIB_DIR${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" \
    RUSTFLAGS="-L native=$LIB_DIR${RUSTFLAGS:+ $RUSTFLAGS}" \
    cargo build --release 2>&1 | tail -3
    echo "   ✓ darkbloom ($(du -h target/release/darkbloom | cut -f1))"
    echo ""
else
    echo "3.5. Reusing existing darkbloom build (--skip-build)"
    echo ""
fi

PROVIDER_BIN="$PROJECT_DIR/provider/target/release/darkbloom"
if [ ! -f "$PROVIDER_BIN" ]; then
    echo "   ERROR: $PROVIDER_BIN not found. Run without --skip-build."
    exit 1
fi

# ─── 4. Copy and code-sign binaries ──────────────────────────
echo "4. Copying and code-signing binaries..."
ENTITLEMENTS="$SCRIPT_DIR/entitlements.plist"
mkdir -p "$BUNDLE_DIR/bin"

cp "$PROVIDER_BIN" "$BUNDLE_DIR/bin/darkbloom"
PYTHON_LOAD_PATH=$(otool -L "$BUNDLE_DIR/bin/darkbloom" | awk '/libpython3\.12\.dylib/ {print $1; exit}')
if [ -z "$PYTHON_LOAD_PATH" ]; then
    echo "   ERROR: could not find libpython linkage in darkbloom"
    exit 1
fi
install_name_tool -change \
    "$PYTHON_LOAD_PATH" \
    "@executable_path/../python/lib/libpython3.12.dylib" \
    "$BUNDLE_DIR/bin/darkbloom"
codesign --force --sign - --entitlements "$ENTITLEMENTS" --options runtime "$BUNDLE_DIR/bin/darkbloom"
echo "   ✓ darkbloom (signed with hypervisor entitlement)"

if [ -f "$ENCLAVE_BIN" ]; then
    cp "$ENCLAVE_BIN" "$BUNDLE_DIR/bin/eigeninference-enclave"
    codesign --force --sign - --entitlements "$ENTITLEMENTS" --options runtime "$BUNDLE_DIR/bin/eigeninference-enclave"
    echo "   ✓ eigeninference-enclave (signed)"
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
    cp "$FFMPEG_SRC" "$BUNDLE_DIR/bin/ffmpeg"
    chmod +x "$BUNDLE_DIR/bin/ffmpeg"
    echo "   ✓ ffmpeg ($(du -h "$BUNDLE_DIR/bin/ffmpeg" | cut -f1), from $FFMPEG_SRC)"
else
    echo "   ⚠ ffmpeg not found. Place a static binary at vendor/ffmpeg or /tmp/ffmpeg-macos-arm64"
    echo "     The installer will attempt to download it at install time."
fi
echo ""

# ─── 6. Include STT server script ────────────────────────────
echo "6. Including stt_server.py..."
STT_SERVER="$PROJECT_DIR/provider/stt_server.py"
if [ -f "$STT_SERVER" ]; then
    cp "$STT_SERVER" "$BUNDLE_DIR/bin/stt_server.py"
    echo "   ✓ stt_server.py"
else
    echo "   ⚠ stt_server.py not found at $STT_SERVER"
fi
echo ""

# ─── 7. Build and include gRPCServerCLI (Draw Things image backend) ──
echo "7. Building gRPCServerCLI (Draw Things community)..."
DRAWTHINGS_DIR="/tmp/draw-things-community"
if [ ! -d "$DRAWTHINGS_DIR" ]; then
    git clone --depth 1 https://github.com/drawthingsai/draw-things-community.git "$DRAWTHINGS_DIR"
fi
cd "$DRAWTHINGS_DIR"
swift build -c release --product gRPCServerCLI 2>&1 | tail -3
GRPC_BIN="$DRAWTHINGS_DIR/.build/arm64-apple-macosx/release/gRPCServerCLI"
if [ -f "$GRPC_BIN" ]; then
    cp "$GRPC_BIN" "$BUNDLE_DIR/bin/gRPCServerCLI"
    chmod +x "$BUNDLE_DIR/bin/gRPCServerCLI"
    echo "   ✓ gRPCServerCLI ($(du -h "$BUNDLE_DIR/bin/gRPCServerCLI" | cut -f1))"
else
    echo "   ⚠ gRPCServerCLI build failed — image generation will not work"
fi
echo ""

# ─── 8. Include image bridge ────────────────────────────────
echo "8. Including image bridge..."
IMAGE_BRIDGE_SRC="$PROJECT_DIR/image-bridge/eigeninference_image_bridge"
if [ -d "$IMAGE_BRIDGE_SRC" ]; then
    mkdir -p "$BUNDLE_DIR/image-bridge/eigeninference_image_bridge"
    cp -r "$IMAGE_BRIDGE_SRC/"*.py "$BUNDLE_DIR/image-bridge/eigeninference_image_bridge/"
    # Copy generated protobuf/flatbuffers if they exist
    [ -d "$IMAGE_BRIDGE_SRC/generated" ] && cp -r "$IMAGE_BRIDGE_SRC/generated" "$BUNDLE_DIR/image-bridge/eigeninference_image_bridge/"
    echo "   ✓ image bridge"
else
    echo "   ⚠ image bridge not found at $IMAGE_BRIDGE_SRC"
fi
echo ""

# ─── 8.5. Compute runtime integrity manifest ─────────────────
echo "8.5. Computing runtime integrity hashes..."

# Use the provider binary itself for hash computation (ensures parity with runtime)
PYTHON_HASH=$(shasum -a 256 "$BUNDLE_DIR/python/bin/python3.12" | cut -d' ' -f1)
echo "   Python hash: ${PYTHON_HASH:0:16}..."

# Hash the full allowed Python runtime tree (stdlib + lib-dynload + site-packages)
# using the same sorted-file algorithm as the provider runtime verifier.
PYTHON_LIB_DIR="$BUNDLE_DIR/python/lib/python3.12"
if [ -d "$PYTHON_LIB_DIR" ]; then
    RUNTIME_HASH=$("$BUNDLE_DIR/python/bin/python3.12" -c "
import hashlib, os, sys
d = sys.argv[1]
files = []
for r, dirs, fs in os.walk(d):
    dirs[:] = [name for name in dirs if name != '__pycache__']
    for f in fs:
        if f.endswith('.pyc'):
            continue
        files.append(os.path.join(r, f))
files.sort()
final = hashlib.sha256()
for path in files:
    h = hashlib.sha256()
    with open(path, 'rb') as fh:
        while True:
            chunk = fh.read(65536)
            if not chunk:
                break
            h.update(chunk)
    final.update(h.digest())  # raw 32 bytes, not hex
print(final.hexdigest())
" "$PYTHON_LIB_DIR")
    echo "   Runtime hash (full python lib): ${RUNTIME_HASH:0:16}..."
else
    RUNTIME_HASH=""
    echo "   ⚠ python runtime lib not found — runtime hash unavailable"
fi

# Hash templates from R2 CDN
TEMPLATE_HASHES_JSON="{"
R2_PUBLIC="https://pub-7cbee059c80c46ec9c071dbee2726f8a.r2.dev"
FIRST_TEMPLATE=true
for template in qwen3.5 trinity gemma4 minimax; do
    HASH=$(curl -fsSL "$R2_PUBLIC/templates/${template}.jinja" 2>/dev/null | shasum -a 256 | cut -d' ' -f1)
    if [ -n "$HASH" ] && [ "$HASH" != "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" ]; then
        [ "$FIRST_TEMPLATE" = false ] && TEMPLATE_HASHES_JSON+=","
        TEMPLATE_HASHES_JSON+="\"${template}\":\"${HASH}\""
        FIRST_TEMPLATE=false
        echo "   Template ${template}: ${HASH:0:16}..."
    fi
done
TEMPLATE_HASHES_JSON+="}"

# Write manifest.json into the bundle
BINARY_HASH_PRE=$(shasum -a 256 "$BUNDLE_DIR/bin/darkbloom" | cut -d' ' -f1)
cat > "$BUNDLE_DIR/manifest.json" << MANIFEST
{
    "python_hash": "$PYTHON_HASH",
    "runtime_hash": "$RUNTIME_HASH",
    "binary_hash": "$BINARY_HASH_PRE",
    "template_hashes": $TEMPLATE_HASHES_JSON
}
MANIFEST
echo "   ✓ manifest.json written"
echo ""

# ─── 9. Create tarball ────────────────────────────────────────
echo "9. Creating tarball..."
rm -f "$TARBALL"
cd /tmp && tar czf "$TARBALL" -C eigeninference-bundle .
TARBALL_SIZE=$(du -h "$TARBALL" | cut -f1)
echo "   ✓ $TARBALL ($TARBALL_SIZE)"
echo ""

# ─── 8. Build macOS app + DMG ─────────────────────────────────
echo "10. Building macOS app..."
cd "$PROJECT_DIR/app/EigenInference"
swift build -c release 2>&1 | tail -3
APP_BIN=$(swift build -c release --show-bin-path)/EigenInference

if [ -f "$APP_BIN" ]; then
    APP_BUILD_DIR="$PROJECT_DIR/build"
    rm -rf "$APP_BUILD_DIR/EigenInference.app"
    mkdir -p "$APP_BUILD_DIR/EigenInference.app/Contents/MacOS" "$APP_BUILD_DIR/EigenInference.app/Contents/Resources"

    # Info.plist
    cat > "$APP_BUILD_DIR/EigenInference.app/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>EigenInference</string>
    <key>CFBundleIdentifier</key><string>io.darkbloom.app</string>
    <key>CFBundleVersion</key><string>0.1.0</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleExecutable</key><string>EigenInference</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

    cp "$APP_BIN" "$APP_BUILD_DIR/EigenInference.app/Contents/MacOS/EigenInference"
    codesign --force --sign - --options runtime "$APP_BUILD_DIR/EigenInference.app/Contents/MacOS/EigenInference" 2>/dev/null
    codesign --force --sign - --options runtime --no-strict "$APP_BUILD_DIR/EigenInference.app" 2>/dev/null

    # Create DMG
    DMG_PATH="$APP_BUILD_DIR/EigenInference-latest.dmg"
    rm -f "$DMG_PATH"
    DMG_TMP="$APP_BUILD_DIR/dmg-staging"
    rm -rf "$DMG_TMP"
    mkdir -p "$DMG_TMP"
    cp -a "$APP_BUILD_DIR/EigenInference.app" "$DMG_TMP/"
    ln -s /Applications "$DMG_TMP/Applications"
    hdiutil create -volname "EigenInference" -srcfolder "$DMG_TMP" -ov -format UDZO "$DMG_PATH" >/dev/null 2>&1
    rm -rf "$DMG_TMP"

    DMG_SIZE=$(du -h "$DMG_PATH" | cut -f1)
    echo "   ✓ EigenInference.app + DMG ($DMG_SIZE)"
else
    echo "   ⚠ Swift build failed — app not included"
fi
echo ""

# ─── 9. Upload (optional) ────────────────────────────────────
if [ "$UPLOAD" = true ]; then
    echo "9. Uploading to server..."
    SSH_KEY="$HOME/.ssh/eigeninference-infra"
    SERVER="ubuntu@34.197.17.112"

    if [ ! -f "$SSH_KEY" ]; then
        echo "   ERROR: SSH key not found at $SSH_KEY"
        exit 1
    fi

    scp -i "$SSH_KEY" "$TARBALL" "$SERVER:/tmp/eigeninference-bundle-macos-arm64.tar.gz"
    ssh -i "$SSH_KEY" "$SERVER" '
        sudo cp /tmp/eigeninference-bundle-macos-arm64.tar.gz /var/www/html/dl/
        sudo chmod 644 /var/www/html/dl/eigeninference-bundle-macos-arm64.tar.gz
    '
    echo "   ✓ Bundle uploaded"

    # Upload DMG
    if [ -f "$APP_BUILD_DIR/EigenInference-latest.dmg" ]; then
        scp -i "$SSH_KEY" "$APP_BUILD_DIR/EigenInference-latest.dmg" "$SERVER:/tmp/EigenInference-latest.dmg"
        ssh -i "$SSH_KEY" "$SERVER" '
            sudo cp /tmp/EigenInference-latest.dmg /var/www/html/dl/EigenInference-latest.dmg
            sudo chmod 644 /var/www/html/dl/EigenInference-latest.dmg
        '
        echo "   ✓ App DMG uploaded"
    fi

    # Upload install script
    scp -i "$SSH_KEY" "$PROJECT_DIR/scripts/install.sh" "$SERVER:/tmp/install.sh"
    ssh -i "$SSH_KEY" "$SERVER" '
        sudo cp /tmp/install.sh /var/www/html/install.sh
        sudo chmod 644 /var/www/html/install.sh
    '
    echo "   ✓ install.sh uploaded"

    # Upload runtime manifest to R2
    if [ -f "$BUNDLE_DIR/manifest.json" ]; then
        echo "   Uploading runtime manifest to R2..."
        python3 -c "
import boto3, os
s3 = boto3.client('s3',
    endpoint_url='https://9e92221750c162ade0f2730f63f4963d.r2.cloudflarestorage.com',
    aws_access_key_id=os.environ['R2_ACCESS_KEY'],
    aws_secret_access_key=os.environ['R2_SECRET_KEY'],
    region_name='auto',
)
s3.upload_file('$BUNDLE_DIR/manifest.json', 'd-inf-models', 'runtime/manifest.json',
    ExtraArgs={'ContentType': 'application/json'})
print('   ✓ manifest.json uploaded to R2')
" 2>/dev/null || echo "   ⚠ R2 upload failed (missing credentials?) — manifest not uploaded"

        # Register runtime hashes with coordinator
        echo "   Registering runtime hashes with coordinator..."
        COORDINATOR="https://api.darkbloom.dev"
        curl -fsSL -X POST "$COORDINATOR/v1/runtime/manifest" \
            -H "Content-Type: application/json" \
            -d @"$BUNDLE_DIR/manifest.json" 2>/dev/null \
            && echo "   ✓ Runtime manifest registered with coordinator" \
            || echo "   ⚠ Could not register manifest (coordinator may not support it yet)"
    fi
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
    echo "    curl -fsSL https://api.darkbloom.dev/install.sh | bash"
else
    echo "  To upload:"
    echo "    ./scripts/build-bundle.sh --upload"
fi
echo ""
echo "════════════════════════════════════════════════════"
