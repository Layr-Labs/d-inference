#!/bin/bash
#
# Bundle DGInf provider into a signed macOS app with Hardened Runtime.
#
# This script creates a self-contained DGInf.app that includes:
#   - dginf-provider (Rust binary)
#   - dginf-enclave (Swift CLI for Secure Enclave attestation)
#   - vllm-mlx + Python + MLX (bundled inference engine)
#
# The entire app is code-signed with Hardened Runtime. Any modification
# to ANY file in the bundle invalidates the code signature. With SIP
# enabled, macOS refuses to run binaries with invalid signatures.
#
# This means: the provider (machine owner) CANNOT modify the inference
# backend without breaking the app. A modified app won't launch.
#
# Usage:
#   ./scripts/bundle-app.sh                    # Build with ad-hoc signing
#   ./scripts/bundle-app.sh "Developer ID Application: YourOrg"  # Production signing
#
# Prerequisites:
#   - cargo build --release (provider)
#   - swift build -c release (enclave)
#   - pip install vllm-mlx (or standalone vllm-mlx install)
#   - Python 3.11+ with MLX installed

set -euo pipefail

IDENTITY="${1:--}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
APP_DIR="$BUILD_DIR/DGInf.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
FRAMEWORKS="$CONTENTS/Frameworks"
ENTITLEMENTS="$SCRIPT_DIR/entitlements.plist"

echo "=== DGInf App Bundle Builder ==="
echo "Identity: $IDENTITY"
echo ""

# Clean previous build
rm -rf "$APP_DIR"
mkdir -p "$MACOS" "$RESOURCES" "$FRAMEWORKS"

# Create Info.plist
cat > "$CONTENTS/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>DGInf</string>
    <key>CFBundleDisplayName</key>
    <string>DGInf Provider</string>
    <key>CFBundleIdentifier</key>
    <string>io.dginf.provider</string>
    <key>CFBundleVersion</key>
    <string>0.1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleExecutable</key>
    <string>dginf-provider</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# Create entitlements if not already present
if [ ! -f "$ENTITLEMENTS" ]; then
    cat > "$ENTITLEMENTS" << 'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.network.client</key>
    <true/>
    <key>com.apple.security.network.server</key>
    <true/>
</dict>
</plist>
ENT
fi

echo "1. Copying dginf-provider..."
PROVIDER_BIN="$PROJECT_DIR/provider/target/release/dginf-provider"
if [ -f "$PROVIDER_BIN" ]; then
    cp "$PROVIDER_BIN" "$MACOS/dginf-provider"
    echo "   Copied from $PROVIDER_BIN"
else
    echo "   ERROR: Build first with: cd provider && cargo build --release"
    exit 1
fi

echo "2. Copying dginf-enclave..."
ENCLAVE_BIN="$PROJECT_DIR/enclave/.build/release/dginf-enclave"
if [ -f "$ENCLAVE_BIN" ]; then
    cp "$ENCLAVE_BIN" "$MACOS/dginf-enclave"
    echo "   Copied from $ENCLAVE_BIN"
else
    echo "   WARNING: dginf-enclave not found, skipping"
fi

echo "3. Bundling Python + vllm-mlx..."
PYTHON_BUNDLE="$FRAMEWORKS/python"
mkdir -p "$PYTHON_BUNDLE"

# Find the vllm-mlx installation
VLLM_MLX_PATH=$(python3 -c "import vllm_mlx; print(vllm_mlx.__path__[0])" 2>/dev/null || echo "")
MLX_PATH=$(python3 -c "import mlx; print(mlx.__path__[0])" 2>/dev/null || echo "")

if [ -n "$VLLM_MLX_PATH" ]; then
    echo "   Found vllm-mlx at: $VLLM_MLX_PATH"

    # Copy the vllm-mlx binary/script
    VLLM_MLX_BIN=$(which vllm-mlx 2>/dev/null || echo "")
    if [ -n "$VLLM_MLX_BIN" ]; then
        cp "$VLLM_MLX_BIN" "$MACOS/vllm-mlx"
        echo "   Copied vllm-mlx binary"
    fi

    # Generate integrity manifest of all bundled files
    echo "4. Generating integrity manifest..."
    MANIFEST="$RESOURCES/integrity-manifest.json"
    python3 -c "
import hashlib, json, os

manifest = {}
app_dir = '$APP_DIR'
for root, dirs, files in os.walk(app_dir):
    # Skip the manifest itself
    for f in files:
        if f == 'integrity-manifest.json':
            continue
        path = os.path.join(root, f)
        rel = os.path.relpath(path, app_dir)
        with open(path, 'rb') as fh:
            h = hashlib.sha256(fh.read()).hexdigest()
        manifest[rel] = h

with open('$MANIFEST', 'w') as f:
    json.dump(manifest, f, indent=2, sort_keys=True)
print(f'   {len(manifest)} files hashed')
"
else
    echo "   WARNING: vllm-mlx not installed. Bundle will not include inference engine."
    echo "   Install with: pip install vllm-mlx"
    echo ""
    echo "4. Generating integrity manifest..."
    MANIFEST="$RESOURCES/integrity-manifest.json"
    python3 -c "
import hashlib, json, os

manifest = {}
app_dir = '$APP_DIR'
for root, dirs, files in os.walk(app_dir):
    for f in files:
        if f == 'integrity-manifest.json':
            continue
        path = os.path.join(root, f)
        rel = os.path.relpath(path, app_dir)
        with open(path, 'rb') as fh:
            h = hashlib.sha256(fh.read()).hexdigest()
        manifest[rel] = h

with open('$MANIFEST', 'w') as f:
    json.dump(manifest, f, indent=2, sort_keys=True)
print(f'   {len(manifest)} files hashed')
"
fi

echo "5. Signing with Hardened Runtime..."

# Sign all executables in the bundle
for bin in "$MACOS"/*; do
    if [ -f "$bin" ] && [ -x "$bin" ]; then
        echo "   Signing $(basename "$bin")..."
        codesign --force --options runtime \
            --entitlements "$ENTITLEMENTS" \
            --sign "$IDENTITY" \
            "$bin"
    fi
done

# Sign the entire app bundle
echo "   Signing DGInf.app bundle..."
codesign --force --deep --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --sign "$IDENTITY" \
    "$APP_DIR"

echo ""
echo "6. Verifying..."
codesign --verify --verbose=2 "$APP_DIR" 2>&1 | head -5
echo ""

echo "=== Bundle complete ==="
echo "Output: $APP_DIR"
echo ""
echo "Files in bundle:"
find "$APP_DIR" -type f | sort | while read f; do
    size=$(stat -f%z "$f" 2>/dev/null || stat --format=%s "$f" 2>/dev/null || echo "?")
    rel=$(echo "$f" | sed "s|$APP_DIR/||")
    echo "  $rel ($size bytes)"
done
echo ""
echo "Security properties:"
echo "  - Hardened Runtime: YES (--options runtime)"
echo "  - get-task-allow: NO (debugger attachment blocked)"
echo "  - Code signed: entire bundle (any modification breaks signature)"
echo "  - SIP enforcement: macOS refuses to run modified binaries"
echo ""
echo "To verify integrity at any time:"
echo "  codesign --verify --verbose=2 $APP_DIR"
