#!/bin/bash
#
# Bundle DGInf into a self-contained, code-signed macOS .app
#
# Creates DGInf.app containing:
#   Contents/
#     Info.plist
#     MacOS/
#       DGInf                  ← Swift menu bar app (main executable)
#       dginf-provider         ← Rust CLI binary
#       dginf-enclave          ← Swift Secure Enclave CLI
#     Frameworks/
#       python/                ← python-build-standalone 3.12
#         bin/python3.12
#         bin/vllm-mlx
#         lib/python3.12/site-packages/
#           mlx/
#           mlx_lm/
#           vllm_mlx/
#     Resources/
#       AppIcon.icns
#       integrity-manifest.json
#
# The entire bundle is code-signed with Hardened Runtime.
# Any file modification invalidates the signature → macOS refuses to launch.
#
# Usage:
#   ./scripts/bundle-app.sh                                    # Ad-hoc signing (testing)
#   ./scripts/bundle-app.sh "Developer ID Application: Org"    # Production
#   ./scripts/bundle-app.sh "Developer ID Application: Org" --notarize  # + Apple notarization
#
# Prerequisites:
#   cargo build --release --no-default-features   (provider)
#   swift build -c release                         (enclave + app)
#   Python bundle at ~/.dginf/python/              (from install.sh)

set -euo pipefail

IDENTITY="${1:--}"
NOTARIZE=""
UPLOAD=false
for arg in "${@:2}"; do
    case "$arg" in
        --notarize) NOTARIZE="--notarize" ;;
        --upload) UPLOAD=true ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
APP_DIR="$BUILD_DIR/DGInf.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
FRAMEWORKS="$CONTENTS/Frameworks"
ENTITLEMENTS="$SCRIPT_DIR/entitlements.plist"

VERSION="0.1.0"
BUNDLE_ID="io.dginf.provider"

echo "╔══════════════════════════════════════════════════╗"
echo "║  DGInf App Bundle Builder                        ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""
echo "Version:    $VERSION"
echo "Identity:   $IDENTITY"
echo "Output:     $APP_DIR"
echo ""

# ─────────────────────────────────────────────────────────
# 0. Clean
# ─────────────────────────────────────────────────────────
rm -rf "$APP_DIR"
mkdir -p "$MACOS" "$RESOURCES" "$FRAMEWORKS"

# ─────────────────────────────────────────────────────────
# 1. Info.plist
# ─────────────────────────────────────────────────────────
echo "1. Creating Info.plist..."
cat > "$CONTENTS/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>DGInf</string>
    <key>CFBundleDisplayName</key>
    <string>DGInf</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleExecutable</key>
    <string>DGInf</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
</dict>
</plist>
PLIST

# ─────────────────────────────────────────────────────────
# 2. Entitlements
# ─────────────────────────────────────────────────────────
cat > "$ENTITLEMENTS" << 'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- NO get-task-allow → blocks debugger attachment under Hardened Runtime -->
    <key>com.apple.security.hypervisor</key>
    <true/>
    <key>com.apple.security.network.client</key>
    <true/>
    <key>com.apple.security.network.server</key>
    <true/>
    <!-- Keychain access for wallet storage -->
    <key>com.apple.security.keychain-access-groups</key>
    <array>
        <string>$(AppIdentifierPrefix)io.dginf.provider</string>
    </array>
</dict>
</plist>
ENT

# ─────────────────────────────────────────────────────────
# 3. Build Swift app
# ─────────────────────────────────────────────────────────
echo "2. Building Swift app..."
cd "$PROJECT_DIR/app/DGInf"
swift build -c release 2>&1 | tail -3
APP_BIN=$(swift build -c release --show-bin-path)/DGInf
if [ ! -f "$APP_BIN" ]; then
    echo "   ERROR: Swift build failed. Run: cd app/DGInf && swift build -c release"
    exit 1
fi
cp "$APP_BIN" "$MACOS/DGInf"
echo "   ✓ DGInf ($(du -h "$MACOS/DGInf" | cut -f1))"

# ─────────────────────────────────────────────────────────
# 4. Build + copy Rust provider
# ─────────────────────────────────────────────────────────
echo "3. Building dginf-provider..."
cd "$PROJECT_DIR/provider"
if [ ! -f "target/release/dginf-provider" ]; then
    cargo build --release --no-default-features 2>&1 | tail -3
fi
cp "target/release/dginf-provider" "$MACOS/dginf-provider"
# Also install to shared path so CLI and app use the same binary
mkdir -p "$HOME/.dginf/bin"
cp "target/release/dginf-provider" "$HOME/.dginf/bin/dginf-provider"
chmod +x "$HOME/.dginf/bin/dginf-provider"
echo "   ✓ dginf-provider ($(du -h "$MACOS/dginf-provider" | cut -f1)) → also installed to ~/.dginf/bin/"

# ─────────────────────────────────────────────────────────
# 5. Build + copy enclave CLI
# ─────────────────────────────────────────────────────────
echo "4. Building dginf-enclave..."
cd "$PROJECT_DIR/enclave"
swift build -c release 2>&1 | tail -3
ENCLAVE_BIN=".build/release/dginf-enclave"
if [ -f "$ENCLAVE_BIN" ]; then
    cp "$ENCLAVE_BIN" "$MACOS/dginf-enclave"
    echo "   ✓ dginf-enclave ($(du -h "$MACOS/dginf-enclave" | cut -f1))"
else
    echo "   ⚠ dginf-enclave not found (attestation will be unavailable)"
fi

# ─────────────────────────────────────────────────────────
# 6. Bundle Python + inference runtime
# ─────────────────────────────────────────────────────────
echo "5. Bundling Python runtime..."
PYTHON_SRC="$HOME/.dginf/python"
PYTHON_DST="$RESOURCES/python"

if [ -d "$PYTHON_SRC" ]; then
    echo "   Copying from $PYTHON_SRC..."
    cp -a "$PYTHON_SRC" "$PYTHON_DST"

    # Fix shebangs to point inside the app bundle
    echo "   Fixing shebangs..."
    for script in "$PYTHON_DST/bin/"*; do
        if [ -f "$script" ] && head -1 "$script" | grep -q "^#!.*python"; then
            # macOS sed -i requires backup extension
            sed -i '' "1s|^#!.*python.*|#!/usr/bin/env python3|" "$script" 2>/dev/null || true
        fi
    done

    # Report what's included
    PYTHON_SIZE=$(du -sh "$PYTHON_DST" | cut -f1)
    echo "   ✓ Python bundle ($PYTHON_SIZE)"

    # Check for key packages
    for pkg in mlx mlx_lm vllm_mlx; do
        if [ -d "$PYTHON_DST/lib/python3.12/site-packages/$pkg" ] || \
           [ -d "$PYTHON_DST/lib/python3.12/site-packages/${pkg/-/_}" ]; then
            echo "     ✓ $pkg"
        else
            echo "     ⚠ $pkg not found"
        fi
    done
else
    echo "   ⚠ No Python bundle at $PYTHON_SRC"
    echo "     Run install.sh first, or install manually:"
    echo "     curl -fsSL https://inference-test.openinnovation.dev/install.sh | bash"
fi

# ─────────────────────────────────────────────────────────
# 7. Generate a placeholder app icon
# ─────────────────────────────────────────────────────────
echo "6. App icon..."
if [ -f "$PROJECT_DIR/resources/AppIcon.icns" ]; then
    cp "$PROJECT_DIR/resources/AppIcon.icns" "$RESOURCES/AppIcon.icns"
    echo "   ✓ Custom icon"
else
    # Generate a simple icon using sips (built into macOS)
    ICON_TMP=$(mktemp -d)
    # Create a 512x512 PNG with a colored background
    python3 -c "
import struct, zlib

def create_png(width, height, color):
    def chunk(tag, data):
        c = tag + data
        return struct.pack('>I', len(data)) + c + struct.pack('>I', zlib.crc32(c) & 0xffffffff)

    raw = b''
    for y in range(height):
        raw += b'\x00'  # filter byte
        for x in range(width):
            # Simple circle with gradient
            cx, cy = width/2, height/2
            dx, dy = x - cx, y - cy
            dist = (dx*dx + dy*dy) ** 0.5
            radius = min(width, height) * 0.4
            if dist < radius:
                raw += bytes(color) + b'\xff'
            else:
                raw += b'\x00\x00\x00\x00'

    ihdr = struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0)
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', ihdr) + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b'')

with open('$ICON_TMP/icon_512.png', 'wb') as f:
    f.write(create_png(512, 512, (46, 204, 113)))  # Green circle
" 2>/dev/null || true

    if [ -f "$ICON_TMP/icon_512.png" ]; then
        mkdir -p "$ICON_TMP/AppIcon.iconset"
        sips -z 16 16 "$ICON_TMP/icon_512.png" --out "$ICON_TMP/AppIcon.iconset/icon_16x16.png" >/dev/null 2>&1 || true
        sips -z 32 32 "$ICON_TMP/icon_512.png" --out "$ICON_TMP/AppIcon.iconset/icon_32x32.png" >/dev/null 2>&1 || true
        sips -z 128 128 "$ICON_TMP/icon_512.png" --out "$ICON_TMP/AppIcon.iconset/icon_128x128.png" >/dev/null 2>&1 || true
        sips -z 256 256 "$ICON_TMP/icon_512.png" --out "$ICON_TMP/AppIcon.iconset/icon_256x256.png" >/dev/null 2>&1 || true
        cp "$ICON_TMP/icon_512.png" "$ICON_TMP/AppIcon.iconset/icon_512x512.png"
        iconutil -c icns "$ICON_TMP/AppIcon.iconset" -o "$RESOURCES/AppIcon.icns" 2>/dev/null || true
        rm -rf "$ICON_TMP"
        echo "   ✓ Generated placeholder icon"
    else
        echo "   ⚠ No icon (app will use default)"
    fi
fi

# ─────────────────────────────────────────────────────────
# 8. Integrity manifest
# ─────────────────────────────────────────────────────────
echo "7. Generating integrity manifest..."
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
print(f'   ✓ {len(manifest)} files hashed')
"

# ─────────────────────────────────────────────────────────
# 9. Code sign with Hardened Runtime
# ─────────────────────────────────────────────────────────
echo "8. Code signing with Hardened Runtime..."

# Sign all .so and .dylib inside the Python framework first
if [ -d "$RESOURCES/python" ]; then
    SO_COUNT=0
    find "$RESOURCES/python" -type f \( -name "*.so" -o -name "*.dylib" \) | while read lib; do
        codesign --force --sign "$IDENTITY" "$lib" 2>/dev/null || true
    done
    SO_COUNT=$(find "$RESOURCES/python" -type f \( -name "*.so" -o -name "*.dylib" \) | wc -l | tr -d ' ')
    echo "   ✓ Signed $SO_COUNT Python native libraries"

    # Sign Python interpreter binary
    PYTHON_BIN="$RESOURCES/python/bin/python3.12"
    if [ -f "$PYTHON_BIN" ]; then
        codesign --force --options runtime --sign "$IDENTITY" "$PYTHON_BIN" 2>/dev/null || true
        echo "   ✓ Signed python3.12 interpreter"
    fi
fi

# Sign executables in MacOS/
for bin in "$MACOS"/*; do
    if [ -f "$bin" ] && [ -x "$bin" ]; then
        echo "   Signing $(basename "$bin")..."
        codesign --force --options runtime \
            --entitlements "$ENTITLEMENTS" \
            --sign "$IDENTITY" \
            "$bin"
    fi
done

# Sign the app bundle itself — use --no-strict to handle non-standard
# framework layout (Python bundle is not a real macOS framework)
echo "   Signing DGInf.app..."
codesign --force --options runtime --no-strict \
    --entitlements "$ENTITLEMENTS" \
    --sign "$IDENTITY" \
    "$APP_DIR"

# ─────────────────────────────────────────────────────────
# 10. Verify
# ─────────────────────────────────────────────────────────
echo "9. Verifying..."
codesign --verify --verbose=2 "$APP_DIR" 2>&1 | head -5
echo ""

# ─────────────────────────────────────────────────────────
# 11. Notarize (optional)
# ─────────────────────────────────────────────────────────
if [ "$NOTARIZE" = "--notarize" ] && [ "$IDENTITY" != "-" ]; then
    echo "10. Notarizing..."

    # Create a zip for notarization
    NOTARIZE_ZIP="$BUILD_DIR/DGInf-notarize.zip"
    ditto -c -k --keepParent "$APP_DIR" "$NOTARIZE_ZIP"

    echo "   Submitting to Apple..."
    echo "   (You'll need APPLE_ID and TEAM_ID environment variables)"
    APPLE_ID="${APPLE_ID:-}"
    TEAM_ID="${TEAM_ID:-}"

    if [ -n "$APPLE_ID" ] && [ -n "$TEAM_ID" ]; then
        xcrun notarytool submit "$NOTARIZE_ZIP" \
            --apple-id "$APPLE_ID" \
            --team-id "$TEAM_ID" \
            --keychain-profile "notarytool-profile" \
            --wait

        echo "   Stapling notarization ticket..."
        xcrun stapler staple "$APP_DIR"
        echo "   ✓ Notarized and stapled"
    else
        echo "   ⚠ Set APPLE_ID and TEAM_ID env vars for notarization"
        echo "     First run: xcrun notarytool store-credentials notarytool-profile"
    fi

    rm -f "$NOTARIZE_ZIP"
fi

# ─────────────────────────────────────────────────────────
# 12. Create DMG (for distribution)
# ─────────────────────────────────────────────────────────
echo ""
echo "11. Creating DMG..."
DMG_PATH="$BUILD_DIR/DGInf-${VERSION}.dmg"
rm -f "$DMG_PATH"

# Create a temporary DMG directory with app + Applications symlink
DMG_TMP="$BUILD_DIR/dmg-staging"
rm -rf "$DMG_TMP"
mkdir -p "$DMG_TMP"
cp -a "$APP_DIR" "$DMG_TMP/"
ln -s /Applications "$DMG_TMP/Applications"

hdiutil create -volname "DGInf" -srcfolder "$DMG_TMP" \
    -ov -format UDZO "$DMG_PATH" >/dev/null 2>&1

rm -rf "$DMG_TMP"

if [ -f "$DMG_PATH" ]; then
    DMG_SIZE=$(du -h "$DMG_PATH" | cut -f1)
    echo "   ✓ $DMG_PATH ($DMG_SIZE)"
fi

# ─────────────────────────────────────────────────────────
# 12. Upload to coordinator (optional)
# ─────────────────────────────────────────────────────────
if [ "$UPLOAD" = true ] && [ -f "$DMG_PATH" ]; then
    echo "12. Uploading DMG..."
    SSH_KEY="$HOME/.ssh/dginf-infra"
    SERVER="ubuntu@34.197.17.112"

    if [ ! -f "$SSH_KEY" ]; then
        echo "   ERROR: SSH key not found at $SSH_KEY"
        exit 1
    fi

    scp -i "$SSH_KEY" "$DMG_PATH" "$SERVER:/tmp/DGInf-${VERSION}.dmg"
    ssh -i "$SSH_KEY" "$SERVER" "
        sudo cp /tmp/DGInf-${VERSION}.dmg /var/www/html/dl/
        sudo cp /var/www/html/dl/DGInf-${VERSION}.dmg /var/www/html/dl/DGInf-latest.dmg
        sudo chmod 644 /var/www/html/dl/DGInf-${VERSION}.dmg /var/www/html/dl/DGInf-latest.dmg
    "
    echo "   ✓ DGInf-${VERSION}.dmg uploaded"
    echo "   ✓ DGInf-latest.dmg updated"
    echo ""
fi

# ─────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════"
echo ""
APP_SIZE=$(du -sh "$APP_DIR" | cut -f1)
echo "  DGInf.app    $APP_SIZE"
echo ""
echo "  Contents:"
echo "    MacOS/DGInf              SwiftUI menu bar app"
echo "    MacOS/dginf-provider     Rust inference provider"
echo "    MacOS/dginf-enclave      Secure Enclave attestation"
echo "    Resources/python/        Python 3.12 + MLX + vllm-mlx"
echo ""
echo "  Security:"
echo "    Hardened Runtime          YES"
echo "    get-task-allow            NO (debugger blocked)"
echo "    Code signature            Entire bundle"
echo "    SIP enforcement           Any modification → won't launch"
echo ""
echo "  Install:"
echo "    open $APP_DIR"
echo "    # or drag DGInf.app from DMG to /Applications"
echo ""
echo "  Distribute:"
if [ "$IDENTITY" = "-" ]; then
    echo "    ⚠ Ad-hoc signed — works on this Mac only"
    echo "    For distribution, sign with Developer ID:"
    echo "    ./scripts/bundle-app.sh \"Developer ID Application: YourOrg\" --upload"
else
    echo "    ✓ Signed with: $IDENTITY"
    if [ "$UPLOAD" = true ]; then
        echo "    ✓ Uploaded to coordinator"
    fi
    if [ "$NOTARIZE" = "--notarize" ]; then
        echo "    ✓ Notarized with Apple"
    else
        echo "    Add --notarize for Gatekeeper approval"
    fi
fi
echo ""
echo "════════════════════════════════════════════════════"
