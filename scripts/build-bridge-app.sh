#!/bin/bash
# Build the WebSocket bridge as a signed macOS app bundle.
# This allows it to access managed profile identities (ACME certs)
# for TLS client authentication.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
APP_DIR="$BUILD_DIR/EigenInferenceBridge.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
BUNDLE_ID="io.eigeninference.ws-bridge"

echo "Building WebSocket bridge app..."

# Build the enclave binary (which includes the bridge)
cd "$PROJECT_DIR/enclave"
swift build -c release 2>&1 | tail -2

# Create app bundle structure
rm -rf "$APP_DIR"
mkdir -p "$MACOS"

# Copy binary
cp .build/release/eigeninference-enclave "$MACOS/eigeninference-bridge"

# Create Info.plist
cat > "$CONTENTS/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>eigeninference-bridge</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>EigenInference Bridge</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>LSBackgroundOnly</key>
    <true/>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>

# Create entitlements
cat > /tmp/bridge-entitlements.plist << ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.network.client</key>
    <true/>
    <key>keychain-access-groups</key>
    <array>
        <string>${BUNDLE_ID}</string>
        <string>com.apple.managed.cms</string>
    </array>
</dict>
</plist>
ENT

# Sign with entitlements
codesign --force --sign - \
    --entitlements /tmp/bridge-entitlements.plist \
    --options runtime \
    "$APP_DIR"

echo "Built: $APP_DIR"
echo "Bundle ID: $BUNDLE_ID"
echo ""
echo "Run: $MACOS/eigeninference-bridge tls-bridge"
