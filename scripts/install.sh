#!/bin/bash
# NOTE: This file is also embedded in the coordinator binary via go:embed.
# The copy at coordinator/api/install.sh must be kept in sync.
set -euo pipefail

# Darkbloom Provider Installer (Swift CLI release v0.5.0+)
# Usage: curl -fsSL https://api.darkbloom.dev/install.sh | bash
#
# This script:
#   1. Fetches the latest signed release from the coordinator
#   2. Downloads the provider app (binaries, metallib, SwiftPM resources)
#   3. Verifies bundle SHA-256 + Apple Developer ID code signature
#   4. Sets up the Secure Enclave identity
#   5. Kicks off MDM enrollment (non-blocking)
#
# Zero prerequisites — just macOS 14+ on Apple Silicon. The Swift CLI
# links mlx-swift directly and ships a colocated mlx.metallib for Metal
# kernels; there is no Python interpreter to install and no inference
# subprocess to spawn.

# Direct-fetch copy: no serve-time templating applied. Override with
#   curl ... | COORD_URL=https://api.dev.darkbloom.xyz bash
# Or fetch the coordinator-served copy at $COORD_URL/install.sh for templating.
COORD_URL="${COORD_URL:-https://api.darkbloom.dev}"
INSTALL_DIR="$HOME/.darkbloom"
BIN_DIR="$INSTALL_DIR/bin"
DARKBLOOM_DESIGNATED_REQUIREMENT='anchor apple generic and identifier "io.darkbloom.provider" and certificate leaf[subject.OU] = "SLDQ2GJ6TL"'
INSTALL_TEST_MODE=0

fail_install() {
    echo "  ✗ $*" >&2
    return 1
}

verify_file_hash() {
    local file=$1
    local expected=$2
    local label=$3
    [ -z "$expected" ] && return 0
    local actual
    actual=$(shasum -a 256 "$file" | cut -d' ' -f1)
    [ "$actual" = "$expected" ] \
        || fail_install "$label hash mismatch (expected $expected, got $actual)."
}

verify_code_requirement() {
    local target=$1
    local deep=$2
    local requirement=$3
    if [ "$deep" = "1" ]; then
        codesign --verify --deep --strict --verbose=2 \
            "-R=$requirement" "$target" >/dev/null 2>&1
    else
        codesign --verify --strict --verbose=2 \
            "-R=$requirement" "$target" >/dev/null 2>&1
    fi
}

verify_staged_app_signature() {
    local app=$1
    local requirement=${2:-$DARKBLOOM_DESIGNATED_REQUIREMENT}
    verify_code_requirement "$app" 1 "$requirement" || {
        fail_install "Staged Darkbloom.app does not satisfy the pinned signature requirement."
        return 1
    }
}

# Stock-macOS binary capability probe. `strings` is an Xcode CLT shim on a
# pristine Mac (it prompts/fails without developer tools), so scan the file
# directly with BSD grep's binary-as-text mode — grep ships in base macOS.
binary_contains_paged_code() {
    local binary=$1
    LC_ALL=C grep -a -q -F 'engine_v2_kv_backend' "$binary"
}

verify_staged_app() {
    local app=$1
    local executable="$app/Contents/MacOS/darkbloom"
    local marker="$app/Contents/Resources/darkbloom-runtime-capabilities/paged-kernel-v1"

    if [ "$INSTALL_TEST_MODE" = "1" ]; then
        codesign --verify --deep --strict --verbose=2 "$app" >/dev/null 2>&1 || {
            fail_install "Strict code-signature verification failed for staged Darkbloom.app."
            return 1
        }
    else
        verify_staged_app_signature "$app" || return 1
    fi

    local code_has_paged=0
    local marker_present=0
    binary_contains_paged_code "$executable" && code_has_paged=1
    [ -f "$marker" ] && marker_present=1
    [ "$code_has_paged" -eq "$marker_present" ] || {
        if [ "$code_has_paged" -eq 1 ]; then
            fail_install "Paged-capable staged app is missing its signed capability marker."
        else
            fail_install "Staged app advertises paged capability without paged runtime code."
        fi
        return 1
    }
    [ "$marker_present" -eq 1 ] || return 0
    [ "$(tr -d '[:space:]' < "$marker")" = "1" ] || {
        fail_install "Paged runtime capability marker is invalid."
        return 1
    }

    shopt -s nullglob
    local paged_resources=(
        "$app/Contents/Resources"/*.bundle/pagedattention.metal
    )
    local expected_resource="$app/Contents/Resources/mlx-swift-lm_MLXLMCommon.bundle/pagedattention.metal"
    [ "${#paged_resources[@]}" -eq 1 ] \
        && [ "${paged_resources[0]}" = "$expected_resource" ] \
        && [ -s "$expected_resource" ] \
        || {
            fail_install "Paged-capable staged app requires exactly one sealed MLXLMCommon pagedattention.metal."
            return 1
        }

    DARKBLOOM_NO_UPDATE_CHECK=1 "$executable" runtime-smoke >/dev/null \
        || {
            fail_install "Packaged paged-kernel runtime smoke failed."
            return 1
        }
}

verify_staged_app_payload() {
    local app=$1
    local binary_hash=$2
    local metallib_hash=$3
    local app_bin="$app/Contents/MacOS"
    [ -n "$binary_hash" ] && [ -n "$metallib_hash" ] || {
        fail_install "App releases require binary_hash and metallib_hash."
        return 1
    }
    verify_file_hash "$app_bin/darkbloom" "$binary_hash" "App binary" \
        && verify_file_hash "$app_bin/mlx.metallib" "$metallib_hash" "App metallib"
}

commit_staged_app() {
    local staged_app=$1
    local install_dir=$2
    local backup="$install_dir/.install-backup-$$-$RANDOM"
    local destination="$install_dir/Darkbloom.app"
    local had_previous=0
    mkdir -p "$backup" "$install_dir/bin"

    if [ -d "$destination" ]; then
        mv "$destination" "$backup/Darkbloom.app" || {
            rm -rf "$backup"
            return 1
        }
        had_previous=1
    fi
    if ! mv "$staged_app" "$destination"; then
        [ "$had_previous" -eq 1 ] \
            && mv "$backup/Darkbloom.app" "$destination" 2>/dev/null || true
        rm -rf "$backup"
        return 1
    fi

    local app_bin="$destination/Contents/MacOS"
    if ! ln -sfn "../Darkbloom.app/Contents/MacOS/darkbloom" "$install_dir/bin/darkbloom" \
        || ! ln -sfn "../Darkbloom.app/Contents/MacOS/darkbloom-enclave" "$install_dir/bin/darkbloom-enclave" \
        || ! ln -sfn "../Darkbloom.app/Contents/MacOS/mlx.metallib" "$install_dir/bin/mlx.metallib" \
        || ! ln -sfn "darkbloom-enclave" "$install_dir/bin/eigeninference-enclave"
    then
        rm -rf "$destination"
        [ "$had_previous" -eq 1 ] \
            && mv "$backup/Darkbloom.app" "$destination" 2>/dev/null || true
        rm -rf "$backup"
        return 1
    fi
    chmod +x "$app_bin/darkbloom" "$app_bin/darkbloom-enclave"
    rm -rf "$backup"
}

commit_staged_flat_bundle() {
    local staged_bin=$1
    local install_dir=$2
    local backup="$install_dir/.install-backup-$$-$RANDOM"
    local destination="$install_dir/bin"
    mkdir -p "$backup"
    if [ -d "$destination" ]; then
        mv "$destination" "$backup/bin" || {
            rm -rf "$backup"
            return 1
        }
    fi
    if ! mv "$staged_bin" "$destination"; then
        [ -d "$backup/bin" ] && mv "$backup/bin" "$destination" 2>/dev/null || true
        rm -rf "$backup"
        return 1
    fi
    chmod +x "$destination/darkbloom" "$destination/darkbloom-enclave"
    ln -sfn "darkbloom-enclave" "$destination/eigeninference-enclave"
    rm -rf "$backup"
}

install_bundle_atomically() {
    local archive=$1
    local install_dir=$2
    local binary_hash=${3:-}
    local metallib_hash=${4:-}
    local stage="$install_dir/.install-staging-$$-$RANDOM"
    rm -rf "$stage"
    mkdir -p "$stage"
    if ! tar xzf "$archive" -C "$stage"; then
        rm -rf "$stage"
        return 1
    fi

    local flat_bin="$stage/bin"
    [ -f "$flat_bin/darkbloom" ] \
        && [ -f "$flat_bin/darkbloom-enclave" ] \
        && [ -f "$flat_bin/mlx.metallib" ] \
        || {
            rm -rf "$stage"
            fail_install "Release bundle is missing required flat verifier files."
            return 1
        }
    verify_file_hash "$flat_bin/darkbloom" "$binary_hash" "Binary" || {
        rm -rf "$stage"
        return 1
    }
    verify_file_hash "$flat_bin/mlx.metallib" "$metallib_hash" "Metallib" || {
        rm -rf "$stage"
        return 1
    }

    if [ -d "$stage/Darkbloom.app" ]; then
        verify_staged_app_payload \
            "$stage/Darkbloom.app" "$binary_hash" "$metallib_hash" || {
            rm -rf "$stage"
            return 1
        }
        verify_staged_app "$stage/Darkbloom.app" || {
            rm -rf "$stage"
            return 1
        }
        commit_staged_app "$stage/Darkbloom.app" "$install_dir" || {
            rm -rf "$stage"
            fail_install "Atomic app swap failed; previous install was restored."
            return 1
        }
    else
        if [ "$INSTALL_TEST_MODE" = "1" ]; then
            codesign --verify --strict --verbose=2 "$flat_bin/darkbloom" >/dev/null 2>&1 || {
                rm -rf "$stage"
                fail_install "Strict signature verification failed for legacy flat artifact."
                return 1
            }
        else
            verify_code_requirement \
                "$flat_bin/darkbloom" 0 "$DARKBLOOM_DESIGNATED_REQUIREMENT" || {
                rm -rf "$stage"
                fail_install "Legacy flat artifact does not satisfy the pinned signature requirement."
                return 1
            }
        fi
        commit_staged_flat_bundle "$flat_bin" "$install_dir" || {
            rm -rf "$stage"
            fail_install "Atomic flat-bundle swap failed; previous install was restored."
            return 1
        }
    fi
    rm -rf "$stage"
}

if [ "${1:-}" = "--verify-staged-app-signature-test" ]; then
    [ "$#" -eq 3 ] || {
        echo "usage: $0 --verify-staged-app-signature-test <app> <requirement>" >&2
        exit 64
    }
    verify_staged_app_signature "$2" "$3"
    exit $?
fi

if [ "${1:-}" = "--install-bundle-test" ]; then
    [ "$#" -eq 5 ] || {
        echo "usage: $0 --install-bundle-test <archive> <install-dir> <binary-hash> <metallib-hash>" >&2
        exit 64
    }
    INSTALL_TEST_MODE=1
    install_bundle_atomically "$2" "$3" "$4" "$5"
    exit $?
fi

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
echo "→ [1/4] Fetching latest release from $COORD_URL ..."

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
echo "→ [2/4] Downloading Darkbloom v${VERSION}..."
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

echo "  Staging and verifying the complete app before touching the live install ..."
if ! install_bundle_atomically "$TARBALL" "$INSTALL_DIR" "$BINARY_HASH" "$METALLIB_HASH"; then
    rm -f "$TARBALL"
    echo "  Existing installation was left unchanged."
    exit 1
fi
rm -f "$TARBALL"
echo "  Strict signature, runtime resources, and atomic swap verified ✓"

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
echo "→ [3/4] Provisioning Secure Enclave identity..."
if "$BIN_DIR/darkbloom-enclave" info >/dev/null 2>&1; then
    echo "  Secure Enclave ✓ (P-256 key generated)"
else
    echo "  Secure Enclave ⚠ (not available on this hardware; provider will run with reduced trust)"
fi

# ─── Step 4: Enrollment + device attestation ─────────────────
echo ""
echo "→ [4/4] Enrollment + device attestation..."

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
        echo "  You can finish this now or later; the provider works either way."
        sleep 2
    else
        echo "  Enrollment ⚠ (coordinator unreachable — enroll later with: darkbloom enroll)"
    fi
else
    echo "  Enrollment ⚠ (could not read serial number — enroll later with: darkbloom enroll)"
fi

# ─── Done ────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║  Install complete                            ║"
echo "╚══════════════════════════════════════════════╝"
echo ""
echo "  Start serving:"
echo ""
echo "    source ~/.zshrc && darkbloom start"
echo ""
