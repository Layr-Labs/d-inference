#!/bin/bash
# NOTE: This file is also embedded in the coordinator binary via go:embed.
# The copy at coordinator/internal/api/install.sh must be kept in sync.
set -euo pipefail

# Darkbloom Provider Installer (Swift CLI release v0.5.0+)
# Usage: curl -fsSL https://api.darkbloom.dev/install.sh | bash
#
# This script:
#   1. Fetches the latest signed release from the coordinator
#   2. Downloads the provider bundle (darkbloom + darkbloom-enclave + mlx.metallib)
#   3. Verifies bundle SHA-256 + Apple Developer ID code signature
#   4. Sets up the Secure Enclave identity
#   5. Optionally enrolls in MDM (device attestation)
#   6. Optionally downloads a starter model
#
# Zero prerequisites — just macOS 14+ on Apple Silicon. The Swift CLI
# links mlx-swift directly and ships a colocated mlx.metallib for Metal
# kernels; there is no Python interpreter to install and no inference
# subprocess to spawn.

# Direct-fetch copy: no serve-time templating applied. Override with
#   curl ... | COORD_URL=https://api.dev.darkbloom.xyz bash
# Or fetch the coordinator-served copy at $COORD_URL/install.sh for templating.
COORD_URL="${COORD_URL:-__DARKBLOOM_COORD_URL__}"
INSTALL_DIR="$HOME/.darkbloom"
BIN_DIR="$INSTALL_DIR/bin"

# Detect interactive vs piped (curl | bash).
if [ -t 0 ]; then
    INTERACTIVE=true
else
    INTERACTIVE=false
fi

echo "╔══════════════════════════════════════════════╗"
echo "║  Darkbloom — Private AI on Verified Macs     ║"
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
MACOS=$(sw_vers -productVersion 2>/dev/null || echo "?")
echo "  $CHIP · ${MEM}GB · macOS $MACOS"
echo ""

# ─── Step 1: Fetch latest release ────────────────────────────
echo "→ [1/5] Fetching latest release from $COORD_URL ..."

RELEASE_JSON=$(curl -fsSL "$COORD_URL/v1/releases/latest" 2>/dev/null || echo "")
if [ -z "$RELEASE_JSON" ]; then
    echo "  ✗ Could not reach coordinator at $COORD_URL"
    echo "    Check your internet connection and try again."
    exit 1
fi

# Extract JSON string fields with sed — no python3 needed (no Xcode CLT prompt).
json_val() { echo "$1" | sed -n "s/.*\"$2\":\"\([^\"]*\)\".*/\1/p"; }
BUNDLE_URL=$(json_val "$RELEASE_JSON" url)
BUNDLE_HASH=$(json_val "$RELEASE_JSON" bundle_hash)
BINARY_HASH=$(json_val "$RELEASE_JSON" binary_hash)
METALLIB_HASH=$(json_val "$RELEASE_JSON" metallib_hash)
VERSION=$(json_val "$RELEASE_JSON" version)
BACKEND=$(json_val "$RELEASE_JSON" backend)

if [ -z "$BUNDLE_URL" ] || [ -z "$BUNDLE_HASH" ] || [ -z "$VERSION" ]; then
    echo "  ✗ Coordinator response missing required fields (url / bundle_hash / version)."
    echo "    Raw response: $RELEASE_JSON"
    exit 1
fi

echo "  Version: $VERSION"
echo "  Backend: ${BACKEND:-mlx-swift}"
echo "  Signed by: Developer ID Application: Eigen Labs, Inc."
echo ""

# ─── Step 2: Download + verify bundle ────────────────────────
echo "→ [2/5] Downloading Darkbloom v${VERSION}..."
mkdir -p "$INSTALL_DIR" "$BIN_DIR"

TARBALL="/tmp/darkbloom-bundle.tar.gz"
curl -f#L "$BUNDLE_URL" -o "$TARBALL"

ACTUAL_HASH=$(shasum -a 256 "$TARBALL" | cut -d' ' -f1)
if [ "$ACTUAL_HASH" != "$BUNDLE_HASH" ]; then
    echo ""
    echo "  ✗ Bundle hash mismatch — refusing to install possibly-tampered binary."
    echo "    Expected: $BUNDLE_HASH"
    echo "    Got:      $ACTUAL_HASH"
    rm -f "$TARBALL"
    exit 1
fi
echo "  Bundle hash verified ✓"

echo "  Installing into $INSTALL_DIR ..."
# The bundle ships as Darkbloom.app/ (contains provisioning profile for
# keychain-access-groups) with bin/ symlinks for backward compatibility.
# Older flat bundles (bin/darkbloom directly) are also handled.
tar xzf "$TARBALL" -C "$INSTALL_DIR"

# New .app bundle layout: Darkbloom.app/Contents/MacOS/{darkbloom,darkbloom-enclave,mlx.metallib}
if [ -d "$INSTALL_DIR/Darkbloom.app" ]; then
    APP_BIN="$INSTALL_DIR/Darkbloom.app/Contents/MacOS"
    chmod +x "$APP_BIN/darkbloom" "$APP_BIN/darkbloom-enclave" 2>/dev/null || true
    # bin/ gets symlinks pointing into the .app bundle
    mkdir -p "$BIN_DIR"
    ln -sfn "$APP_BIN/darkbloom" "$BIN_DIR/darkbloom"
    ln -sfn "$APP_BIN/darkbloom-enclave" "$BIN_DIR/darkbloom-enclave"
    ln -sfn "$APP_BIN/mlx.metallib" "$BIN_DIR/mlx.metallib" 2>/dev/null || true
    echo "  Installed .app bundle with provisioning profile"
else
    # Legacy flat layout fallback
    [ -f "$INSTALL_DIR/darkbloom" ]               && mv -f "$INSTALL_DIR/darkbloom" "$BIN_DIR/darkbloom"
    [ -f "$INSTALL_DIR/darkbloom-enclave" ]       && mv -f "$INSTALL_DIR/darkbloom-enclave" "$BIN_DIR/darkbloom-enclave"
    if [ -f "$INSTALL_DIR/eigeninference-enclave" ] && [ ! -f "$BIN_DIR/darkbloom-enclave" ]; then
        mv -f "$INSTALL_DIR/eigeninference-enclave" "$BIN_DIR/darkbloom-enclave"
    fi
    [ -f "$INSTALL_DIR/mlx.metallib" ]            && mv -f "$INSTALL_DIR/mlx.metallib" "$BIN_DIR/mlx.metallib"
    chmod +x "$BIN_DIR/darkbloom" "$BIN_DIR/darkbloom-enclave" 2>/dev/null || true
fi

ln -sfn "$BIN_DIR/darkbloom-enclave" "$BIN_DIR/eigeninference-enclave" 2>/dev/null || true
rm -f "$TARBALL"

# Verify per-binary SHA matches what the coordinator registered. The bundle
# hash above proves the tarball matches; this also proves codesign + notary
# didn't quietly mutate the binary.
if [ -n "${BINARY_HASH:-}" ]; then
    ACTUAL_BIN=$(shasum -a 256 "$BIN_DIR/darkbloom" | cut -d' ' -f1)
    if [ "$ACTUAL_BIN" != "$BINARY_HASH" ]; then
        echo "  ✗ Binary hash mismatch (expected $BINARY_HASH, got $ACTUAL_BIN)."
        rm -rf "$BIN_DIR"
        exit 1
    fi
    echo "  Binary hash verified ✓"
fi
if [ -n "$METALLIB_HASH" ] && [ -f "$BIN_DIR/mlx.metallib" ]; then
    ACTUAL_LIB=$(shasum -a 256 "$BIN_DIR/mlx.metallib" | cut -d' ' -f1)
    if [ "$ACTUAL_LIB" != "$METALLIB_HASH" ]; then
        echo "  ✗ mlx.metallib hash mismatch (expected $METALLIB_HASH, got $ACTUAL_LIB)."
        rm -rf "$BIN_DIR"
        exit 1
    fi
    echo "  Metallib hash verified ✓"
fi

# Verify code signature (codesign is base macOS, no CLT prompt).
if codesign --verify --verbose "$BIN_DIR/darkbloom" 2>/dev/null; then
    TEAM=$(codesign -dvv "$BIN_DIR/darkbloom" 2>&1 | grep "TeamIdentifier=" | cut -d= -f2)
    echo "  Code signature verified ✓ (Team: $TEAM)"
else
    echo "  ⚠ Code signature could not be verified — proceed with caution."
fi

# Make available in PATH. Try /usr/local/bin symlink, fall back to shell rc.
if ln -sf "$BIN_DIR/darkbloom" /usr/local/bin/darkbloom 2>/dev/null; then
    :
fi
RC="$HOME/.zshrc"
if [ -f "$HOME/.bashrc" ] && [ ! -f "$HOME/.zshrc" ]; then
    RC="$HOME/.bashrc"
fi
if ! grep -q "\.darkbloom/bin" "$RC" 2>/dev/null; then
    sed -i '' '/\.dginf\/bin/d; /\.eigeninference\/bin/d; /alias eigeninf/d; /alias dginf/d; /# EigenInference/d; /# Darkbloom$/d' "$RC" 2>/dev/null || true
    cat >> "$RC" << 'SHELL'

# Darkbloom
export PATH="$HOME/.darkbloom/bin:$PATH"
SHELL
fi
export PATH="$BIN_DIR:$PATH"

# Source rc so commands work in this shell. Disable -eu around it: rc files
# may use unbound vars or shell-specific builtins that fail under bash strict.
set +eu
source "$RC" 2>/dev/null || true
set -eu

echo "  Binaries installed ✓"
echo "  Shortcut: darkbloom"

# ─── Migrate from old installs ───────────────────────────────
# Migration chain: ~/.dginf → ~/.eigeninference → ~/.darkbloom
for OLD_DIR in "$HOME/.dginf" "$HOME/.eigeninference"; do
    if [ -d "$OLD_DIR" ] && [ ! -L "$OLD_DIR" ]; then
        echo ""
        echo "  Migrating from $OLD_DIR..."
        for f in enclave_key.data wallet_key auth_token; do
            [ -f "$OLD_DIR/$f" ] && cp -n "$OLD_DIR/$f" "$INSTALL_DIR/$f" 2>/dev/null || true
        done
        # Symlink old path so stragglers still work, then drop the old python/
        # subtree -- the Swift release no longer needs it.
        ln -sfn "$INSTALL_DIR" "$OLD_DIR" 2>/dev/null || true
        echo "  Migration complete ✓"
    fi
done

# ─── Step 3: Secure Enclave identity ─────────────────────────
echo ""
echo "→ [3/5] Provisioning Secure Enclave identity..."
if "$BIN_DIR/darkbloom-enclave" info >/dev/null 2>&1; then
    echo "  Secure Enclave ✓ (P-256 key generated)"
else
    echo "  Secure Enclave ⚠ (not available on this hardware; provider will run with reduced trust)"
fi

# ─── Step 4: Enrollment + device attestation ─────────────────
echo ""
echo "→ [4/5] Enrollment + device attestation..."

ALREADY_ENROLLED=false
if profiles status -type enrollment 2>&1 | grep -q "MDM enrollment: Yes"; then
    ALREADY_ENROLLED=true
fi

if [ "$ALREADY_ENROLLED" = true ]; then
    echo "  Already enrolled ✓"
elif [ -n "$SERIAL" ]; then
    echo "  Requesting enrollment profile from coordinator..."
    PROFILE_PATH="/tmp/Darkbloom-Enroll-${SERIAL}.mobileconfig"
    rm -f "$PROFILE_PATH" 2>/dev/null
    if curl -fsSL -X POST "$COORD_URL/v1/enroll" \
        -H "Content-Type: application/json" \
        -d "{\"serial_number\": \"$SERIAL\"}" \
        -o "$PROFILE_PATH" 2>/dev/null; then
        echo ""
        echo "  ┌──────────────────────────────────────────────────┐"
        echo "  │ ACTION REQUIRED: Install the enrollment profile  │"
        echo "  │                                                  │"
        echo "  │ This profile lets the coordinator verify:        │"
        echo "  │  • SIP, Secure Boot, system integrity            │"
        echo "  │  • Your Secure Enclave is genuine Apple silicon  │"
        echo "  │  • Device identity signed by Apple's Root CA     │"
        echo "  │                                                  │"
        echo "  │ Darkbloom CANNOT erase, lock, or control         │"
        echo "  │ your Mac. Remove anytime in System Settings.     │"
        echo "  └──────────────────────────────────────────────────┘"
        echo ""
        open "$PROFILE_PATH"
        sleep 1
        open "x-apple.systempreferences:com.apple.Profiles-Settings.extension"

        echo "  System Settings opened — click Install and enter your password."
        if [ "$INTERACTIVE" = true ]; then
            echo ""
            read -p "  Press Enter once you have installed the profile..." || true
        else
            echo "  After installing, the provider will verify on first start."
            sleep 3
        fi
        echo "  Enrollment ✓"
    else
        echo "  Enrollment ⚠ (coordinator unreachable — enroll later with: darkbloom enroll)"
    fi
else
    echo "  Enrollment ⚠ (could not read serial number — enroll later with: darkbloom enroll)"
fi

# ─── Step 5: Optional starter model ──────────────────────────
echo ""
echo "→ [5/5] Inference model..."

CATALOG_JSON=$(curl -fsSL "$COORD_URL/v1/models/catalog?type=text" 2>/dev/null || echo "")

if [ -n "$CATALOG_JSON" ]; then
    if [ "$INTERACTIVE" = true ]; then
        echo ""
        echo "  Available text models:"
        echo "$CATALOG_JSON" \
          | tr ',' '\n' \
          | sed -n 's/.*"id":"\([^"]*\)".*"display_name":"\([^"]*\)".*"size_gb":\([0-9.]*\).*"min_ram_gb":\([0-9]*\).*/  • \2  ~\3 GB  (≥\4 GB RAM)  [\1]/p' \
          | head -20
        echo ""
        echo "  Download a model with:"
        echo "    darkbloom models download <id>"
    else
        echo "  Run interactively to pick a starter model:"
        echo "    curl -fsSL $COORD_URL/install.sh | bash -s"
        echo "  Or list the catalog with:  darkbloom models catalog"
    fi
else
    echo "  Could not fetch model catalog (continuing anyway)."
fi

# ─── Done ────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║  Install complete                            ║"
echo "╚══════════════════════════════════════════════╝"
echo ""
echo "  Next steps:"
echo "    darkbloom doctor             # verify the system is ready"
echo "    darkbloom models catalog     # browse available models"
echo "    darkbloom models download <id>"
echo "    darkbloom login              # link this Mac to your account"
echo "    darkbloom start              # serve inference (interactive picker)"
echo ""
