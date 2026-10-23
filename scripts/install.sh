#!/bin/bash
# Canonical provider installer. Coordinate reviewed byte-for-byte updates of the
# platform-served snapshot in Layr-Labs/darkbloom-platform; it is not synced here.
set -euo pipefail

# Darkbloom Provider Installer (Swift CLI release v0.5.0+)
# Usage: curl -fsSL <coordinator base URL>/install.sh | bash
#
# This script:
#   1. Fetches the latest signed release from the coordinator that served it
#      and selects the provider identity from the release version
#   2. Downloads the provider app (binaries, metallib, SwiftPM resources)
#   3. Verifies bundle SHA-256 + Apple Developer ID code signature
#   4. Sets up the Secure Enclave identity
#   5. Explains App Attest setup or defers legacy enrollment to the signed CLI flow
#   6. Optionally downloads a starter model
#
# Zero prerequisites — just macOS 14+ on Apple Silicon. The Swift CLI
# links mlx-swift directly and ships a colocated mlx.metallib for Metal
# kernels; there is no Python interpreter to install and no inference
# subprocess to spawn.

# This source intentionally retains the placeholder used by the coordinator.
# End users fetch /install.sh from a coordinator, which substitutes its own base
# URL. Direct source execution must set COORD_URL explicitly.
COORD_URL="${COORD_URL:-__DARKBLOOM_COORD_URL__}"
# The provider connects here when provider.toml sets no [coordinator] url
# (CoordinatorSettings in provider-swift ProviderConfig.swift), so the
# production installer removes that url instead of writing one.
PRODUCTION_COORD_URL="https://api.darkbloom.dev"
DARKBLOOM_DESIGNATED_REQUIREMENT='anchor apple generic and identifier "io.darkbloom.provider" and certificate leaf[subject.OU] = "SLDQ2GJ6TL"'
# Pre-release builds (versions carrying -dev. or -staging.) are self-signed and
# served only by the dev and staging coordinators, which accept an ad-hoc or
# otherwise non-Apple-anchored signature. For those the Apple-anchor and team-OU
# clause is dropped; the bundle identifier io.darkbloom.provider stays pinned and
# every other check (deep/strict verify and the staged-app checks) is unchanged.
DARKBLOOM_PRERELEASE_DESIGNATED_REQUIREMENT='identifier "io.darkbloom.provider"'
DARKBLOOM_FAN_HELPER_REQUIREMENT='anchor apple generic and identifier "io.darkbloom.fan-helper" and certificate leaf[subject.OU] = "SLDQ2GJ6TL"'
FAN_HELPER_REQUIREMENT="$DARKBLOOM_FAN_HELPER_REQUIREMENT"
INSTALL_TEST_MODE=0

# A dev release (version X.Y.Z-dev.N) or a staging release (X.Y.Z-staging.N)
# installs as its own provider beside the production provider. The identities
# share no name and no path, so one install never reads, moves or deletes
# another's files. Nothing may use these names or paths before this function runs.
select_provider_identity() {
    # Classify by the SemVer pre-release component, not an unanchored substring.
    # Strip any +build metadata first, then take the segment after the first "-".
    # A marker that appears only in build metadata (e.g. 1.2.3+x-dev.y) is not a
    # pre-release and stays prod, so it never relaxes the signature requirement.
    local prerelease=
    case "${1%%+*}" in
        *-*) prerelease="${1%%+*}" ; prerelease="${prerelease#*-}" ;;
    esac
    case "$prerelease" in
        dev.*)
            PROVIDER_LABEL="Darkbloom Dev"
            CLI_NAME="darkbloom-dev"
            ENCLAVE_NAME="darkbloom-enclave-dev"
            ;;
        staging.*)
            PROVIDER_LABEL="Darkbloom Staging"
            CLI_NAME="darkbloom-staging"
            ENCLAVE_NAME="darkbloom-enclave-staging"
            ;;
        *)
            PROVIDER_LABEL="Darkbloom"
            CLI_NAME="darkbloom"
            ENCLAVE_NAME="darkbloom-enclave"
            ;;
    esac
    # Choose the designated requirement from the same pre-release component. A
    # pre-release version relaxes only the Apple-anchor/team-OU clause; prod gets
    # the full Apple-team requirement. A prod coordinator is never served a
    # pre-release version, so the relaxed branch is unreachable on prod.
    case "$prerelease" in
        dev.*|staging.*)
            DESIGNATED_REQUIREMENT="$DARKBLOOM_PRERELEASE_DESIGNATED_REQUIREMENT"
            ;;
        *)
            DESIGNATED_REQUIREMENT="$DARKBLOOM_DESIGNATED_REQUIREMENT"
            ;;
    esac
    APP_NAME="$PROVIDER_LABEL.app"
    INSTALL_DIR="$HOME/.$CLI_NAME"
    BIN_DIR="$INSTALL_DIR/bin"
    PROVIDER_CONFIG="$HOME/.config/$CLI_NAME/provider.toml"
}

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
    # Defaults to the per-identity requirement that select_provider_identity
    # chose from the version marker (relaxed for pre-release, full for prod).
    local requirement=${2:-$DESIGNATED_REQUIREMENT}
    verify_code_requirement "$app" 1 "$requirement" || {
        fail_install "Staged $APP_NAME does not satisfy the pinned signature requirement."
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

verify_fan_helper_capability() {
    local app=$1
    local executable="$app/Contents/MacOS/$CLI_NAME"
    local marker="$app/Contents/Resources/darkbloom-runtime-capabilities/fan-helper-v1"
    local helper="$app/Contents/Helpers/darkbloom-fan-helper"
    local code_present=0
    local marker_present=0
    local helper_present=0

    LC_ALL=C grep -a -q -F 'darkbloom-fan-helper-v1' "$executable" \
        && code_present=1
    if [ -e "$marker" ] || [ -L "$marker" ]; then marker_present=1; fi
    if [ -e "$helper" ] || [ -L "$helper" ]; then helper_present=1; fi
    [ "$code_present" -eq "$marker_present" ] \
        && [ "$marker_present" -eq "$helper_present" ] || {
        fail_install "Fan-helper CLI capability, marker, and nested helper must be present together."
        return 1
    }
    [ "$marker_present" -eq 1 ] || return 0

    [ -f "$marker" ] && [ ! -L "$marker" ] \
        && [ "$(tr -d '[:space:]' < "$marker")" = "1" ] || {
        fail_install "Fan-helper capability marker is invalid."
        return 1
    }
    [ -f "$helper" ] && [ ! -L "$helper" ] && [ -x "$helper" ] || {
        fail_install "Bundled fan helper must be a regular executable, not a symlink."
        return 1
    }
    [ "$(stat -f '%Lp' "$helper" 2>/dev/null || true)" = "755" ] || {
        fail_install "Bundled fan helper must have mode 0755."
        return 1
    }
    verify_code_requirement "$helper" 0 "$FAN_HELPER_REQUIREMENT" || {
        fail_install "Bundled fan helper does not satisfy the pinned helper signature requirement."
        return 1
    }
}

verify_staged_app() {
    local app=$1
    local executable="$app/Contents/MacOS/$CLI_NAME"
    local marker="$app/Contents/Resources/darkbloom-runtime-capabilities/paged-kernel-v1"

    if [ "$INSTALL_TEST_MODE" = "1" ]; then
        codesign --verify --deep --strict --verbose=2 "$app" >/dev/null 2>&1 || {
            fail_install "Strict code-signature verification failed for staged $APP_NAME."
            return 1
        }
    else
        verify_staged_app_signature "$app" || return 1
    fi
    verify_fan_helper_capability "$app" || return 1

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
    [ "$marker_present" -eq 1 ] || {
        fail_install "Staged app predates the paged runtime; pre-paged releases are no longer installable."
        return 1
    }
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

    local smoke_output
    smoke_output=$(DARKBLOOM_NO_UPDATE_CHECK=1 \
        DARKBLOOM_GEMMA4_PREFILL_CHUNK_EVAL=18 \
        MLX_GEMMA4_FUSED_WEIGHTED_UNSORT=1 \
        MLX_GATHER_QMM_EXPERT_SLICES=1 \
        "$executable" runtime-smoke 2>&1) \
        || {
            if ! printf '%s\n' "$smoke_output" | grep -q '^app-attest-callback-runtime-smoke: ok$' \
                && [ -f "$app/Contents/Resources/darkbloom-runtime-capabilities/app-attest-callback-v1" ]; then
                fail_install "Packaged App Attest callback runtime smoke failed."
            else
                fail_install "Packaged runtime smoke failed (App Attest, configuration, or Metal)."
            fi
            return 1
        }
    if [ -f "$app/Contents/Resources/darkbloom-runtime-capabilities/app-attest-callback-v1" ]; then
        printf '%s\n' "$smoke_output" | grep -q '^app-attest-callback-runtime-smoke: ok$' || {
            fail_install "Packaged App Attest callback runtime smoke omitted its success marker."
            return 1
        }
    fi
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
    verify_file_hash "$app_bin/$CLI_NAME" "$binary_hash" "App binary" \
        && verify_file_hash "$app_bin/mlx.metallib" "$metallib_hash" "App metallib"
}

commit_staged_app() {
    local staged_app=$1
    local install_dir=$2
    local backup="$install_dir/.install-backup-$$-$RANDOM"
    local destination="$install_dir/$APP_NAME"
    local had_previous=0
    mkdir -p "$backup" "$install_dir/bin"

    if [ -d "$destination" ]; then
        mv "$destination" "$backup/$APP_NAME" || {
            rm -rf "$backup"
            return 1
        }
        had_previous=1
    fi
    if ! mv "$staged_app" "$destination"; then
        [ "$had_previous" -eq 1 ] \
            && mv "$backup/$APP_NAME" "$destination" 2>/dev/null || true
        rm -rf "$backup"
        return 1
    fi

    local app_bin="$destination/Contents/MacOS"
    if ! ln -sfn "../$APP_NAME/Contents/MacOS/$CLI_NAME" "$install_dir/bin/$CLI_NAME" \
        || ! ln -sfn "../$APP_NAME/Contents/MacOS/$ENCLAVE_NAME" "$install_dir/bin/$ENCLAVE_NAME" \
        || ! ln -sfn "../$APP_NAME/Contents/MacOS/mlx.metallib" "$install_dir/bin/mlx.metallib"
    then
        rm -rf "$destination"
        [ "$had_previous" -eq 1 ] \
            && mv "$backup/$APP_NAME" "$destination" 2>/dev/null || true
        rm -rf "$backup"
        return 1
    fi
    chmod +x "$app_bin/$CLI_NAME" "$app_bin/$ENCLAVE_NAME"
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
    # Restore ordinary release modes without changing private-state creation
    # elsewhere in the installer or enabling tar's full-permissions mode.
    if ! (umask 022; /usr/bin/tar xzf "$archive" -C "$stage"); then
        rm -rf "$stage"
        return 1
    fi

    # The flat verifier names are the coordinator's release-artifact contract
    # (bin/darkbloom) and are the same for both provider identities.
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

    local staged_app="$stage/$APP_NAME"
    [ -d "$staged_app" ] || {
        rm -rf "$stage"
        fail_install "Release bundle has no $APP_NAME; flat-only bundles are no longer installable."
        return 1
    }
    local name
    for name in "$CLI_NAME" "$ENCLAVE_NAME"; do
        [ -f "$staged_app/Contents/MacOS/$name" ] || {
            rm -rf "$stage"
            fail_install "Release bundle $APP_NAME has no Contents/MacOS/$name, which a $PROVIDER_LABEL release must contain."
            return 1
        }
    done
    verify_staged_app_payload \
        "$staged_app" "$binary_hash" "$metallib_hash" || {
        rm -rf "$stage"
        return 1
    }
    verify_staged_app "$staged_app" || {
        rm -rf "$stage"
        return 1
    }
    commit_staged_app "$staged_app" "$install_dir" || {
        rm -rf "$stage"
        fail_install "Atomic app swap failed; previous install was restored."
        return 1
    }
    rm -rf "$stage"
}

# Accept only a bare host[:port]: the value is written into TOML. Plain
# http:// (ws://) is accepted only for a coordinator on this Mac.
provider_websocket_url() {
    local base=${1%/} scheme host
    local host_pattern='^[A-Za-z0-9.-]+(:[0-9]+)?$'
    case "$base" in
        https://*) scheme=wss; host=${base#https://} ;;
        http://*) scheme=ws; host=${base#http://} ;;
        *) return 1 ;;
    esac
    [[ $host =~ $host_pattern ]] || return 1
    if [ "$scheme" = ws ]; then
        case "${host%%:*}" in
            localhost|127.0.0.1) ;;
            *) return 1 ;;
        esac
    fi
    printf '%s://%s/ws/provider\n' "$scheme" "$host"
}

# Bind the provider to the coordinator that served this installer, so that
# start, login, update and the LaunchAgent use it. For production, remove any
# [coordinator] url so the provider uses its built-in production default
# (this also moves a Mac back from dev); a missing file stays missing. For any
# other coordinator, write its url. Every other line is kept.
bind_provider_coordinator() {
    local coord_url=${1%/}
    local config=$2
    local ws_url=""
    if [ "$coord_url" = "$PRODUCTION_COORD_URL" ]; then
        [ -f "$config" ] || return 0
    else
        ws_url=$(provider_websocket_url "$coord_url") || {
            fail_install "Coordinator URL must be https://<host>[:port], or http:// for localhost (got $coord_url)."
            return 1
        }
        mkdir -p "$(dirname "$config")" || return 1
    fi
    local line=""
    [ -n "$ws_url" ] && line="url = \"$ws_url\""
    local tmp="$config.install-$$"
    if [ -f "$config" ]; then
        # An empty line value removes the url instead of writing one; awk then
        # exits 3 when there was no url to remove, and the file is not touched.
        local status=0
        awk -v line="$line" '
            /^[[:space:]]*\[/ {
                if (in_coordinator && !written && line != "") { print line; written = 1 }
                in_coordinator = ($0 ~ /^[[:space:]]*\[coordinator\][[:space:]]*(#.*)?$/)
                print
                next
            }
            in_coordinator && /^[[:space:]]*url[[:space:]]*=/ {
                if (!written && line != "") { print line; written = 1 }
                removed = 1
                next
            }
            { print }
            END {
                if (line == "") exit(removed ? 0 : 3)
                if (in_coordinator && !written) { print line; written = 1 }
                if (!written) { print ""; print "[coordinator]"; print line }
            }
        ' "$config" > "$tmp" || status=$?
        [ "$status" -eq 0 ] || [ "$status" -eq 3 ] || { rm -f "$tmp"; return 1; }
        if [ "$status" -eq 3 ] || cmp -s "$tmp" "$config"; then
            rm -f "$tmp"
            [ -z "$ws_url" ] || echo "  Coordinator: $ws_url (already set in $config)"
            return 0
        fi
    else
        printf '[coordinator]\n%s\n' "$line" > "$tmp" || { rm -f "$tmp"; return 1; }
    fi
    mv "$tmp" "$config" || { rm -f "$tmp"; return 1; }
    if [ -n "$ws_url" ]; then
        echo "  Coordinator: $ws_url (set in $config)"
    else
        echo "  Coordinator: production default (removed [coordinator] url from $config)"
    fi
    echo "  A provider that is already running keeps its old coordinator until $CLI_NAME start."
}

# Setup routing is independent of serving authorization. App Attest failures
# must not silently send a macOS 27+ user into MDM enrollment.
configure_device_verification() {
    echo "  New providers require macOS 27+ and qualified current App Attest."
    echo "  Grandfathered legacy providers may temporarily serve without base rewards."
    echo "  All base rewards require macOS 27+ and qualified current App Attest."
    local macos_major=${MACOS%%.*}
    case "$macos_major" in
        ''|*[!0-9]*)
            echo "  Could not determine the macOS version; no MDM profile was downloaded."
            echo "  Run $CLI_NAME login with your existing account, then $CLI_NAME enroll"
            echo "  to select the verification setup for this Mac."
            return
            ;;
    esac

    echo "  Darkbloom MDM will be deactivated soon."
    if [ "$macos_major" -ge 27 ]; then
        echo "  macOS 27 or later: use App Attest without Darkbloom MDM enrollment."
        echo "  Run $CLI_NAME login, then $CLI_NAME start, and check $CLI_NAME status."
        echo "  Serving starts only after the coordinator approves this connection."
        echo "  If approval is pending or unavailable, run $CLI_NAME doctor."
        echo "  Existing management profiles are kept in place."
        echo "  To remove an existing Darkbloom profile, run $CLI_NAME unenroll"
        echo "  and choose App Attest once removal is approved."
        return
    fi

    echo "  Upgrade to macOS 27 or later for App Attest."
    if profiles status -type enrollment 2>&1 | grep -q "MDM enrollment: Yes"; then
        echo "  An MDM profile is already installed; keep existing management in place."
        echo "  Run $CLI_NAME doctor to check Darkbloom verification."
    fi
    echo "  Legacy re-enrollment is deferred; this installer downloads no MDM profile."
    echo "  If you need legacy re-enrollment, after installation run:"
    echo "    $CLI_NAME login   # sign in to your existing account"
    echo "    $CLI_NAME enroll  # performs the current signed eligibility check"
    echo "  Only eligible grandfathered providers can re-enroll; installation continues."
}

if [ "${1:-}" = "--verify-staged-app-signature-test" ]; then
    [ "$#" -eq 3 ] || {
        echo "usage: $0 --verify-staged-app-signature-test <app> <requirement>" >&2
        exit 64
    }
    select_provider_identity production
    verify_staged_app_signature "$2" "$3"
    exit $?
fi

if [ "${1:-}" = "--bind-coordinator-test" ]; then
    [ "$#" -eq 2 ] || {
        echo "usage: COORD_URL=<url> $0 --bind-coordinator-test <provider-toml>" >&2
        exit 64
    }
    select_provider_identity production
    bind_provider_coordinator "$COORD_URL" "$2"
    exit $?
fi

if [ "${1:-}" = "--install-bundle-test" ]; then
    { [ "$#" -eq 5 ] || [ "$#" -eq 6 ]; } || {
        echo "usage: $0 --install-bundle-test <archive> <install-dir> <binary-hash> <metallib-hash> [fan-helper-requirement]" >&2
        exit 64
    }
    INSTALL_TEST_MODE=1
    select_provider_identity production
    if [ "$#" -eq 6 ]; then FAN_HELPER_REQUIREMENT=$6; fi
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

select_provider_identity "$VERSION"

echo "  Version: $VERSION"
echo "  Provider: $PROVIDER_LABEL ($CLI_NAME, installs in $INSTALL_DIR)"
echo "  Backend: ${BACKEND:-mlx-swift}"
echo "  Signed by: Developer ID Application: Eigen Labs, Inc."
echo ""

# ─── Step 2: Download + verify bundle ────────────────────────
echo "→ [2/5] Downloading $PROVIDER_LABEL v${VERSION}..."
mkdir -p "$INSTALL_DIR" "$BIN_DIR"

TARBALL="${TMPDIR:-/tmp}/$CLI_NAME-bundle.tar.gz"
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
if ln -sf "$BIN_DIR/$CLI_NAME" "/usr/local/bin/$CLI_NAME" 2>/dev/null; then
    :
fi
RC="$HOME/.zshrc"
if [ -f "$HOME/.bashrc" ] && [ ! -f "$HOME/.zshrc" ]; then
    RC="$HOME/.bashrc"
fi
if ! grep -qF ".$CLI_NAME/bin" "$RC" 2>/dev/null; then
    sed -i '' "/\\.dginf\\/bin/d; /\\.eigeninference\\/bin/d; /alias eigeninf/d; /alias dginf/d; /# EigenInference/d; /# $PROVIDER_LABEL\$/d" "$RC" 2>/dev/null || true
    printf "\n# %s\nexport PATH=\"\$HOME/.%s/bin:\$PATH\"\n" "$PROVIDER_LABEL" "$CLI_NAME" >> "$RC"
fi
export PATH="$BIN_DIR:$PATH"

# Source rc so commands work in this shell. Disable -eu around it: rc files
# may use unbound vars or shell-specific builtins that fail under bash strict.
set +eu
source "$RC" 2>/dev/null || true
set -eu

echo "  Binaries installed ✓"
echo "  Shortcut: $CLI_NAME"

if ! bind_provider_coordinator "$COORD_URL" "$PROVIDER_CONFIG"; then
    echo "  Could not write the coordinator URL to $PROVIDER_CONFIG."
    exit 1
fi

# ─── Step 3: Secure Enclave identity ─────────────────────────
echo ""
echo "→ [3/5] Provisioning Secure Enclave identity..."
if "$BIN_DIR/$ENCLAVE_NAME" info >/dev/null 2>&1; then
    echo "  Secure Enclave ✓ (P-256 key generated)"
else
    echo "  Secure Enclave ⚠ (not available on this hardware; provider will run with reduced trust)"
fi

# ─── Step 4: Enrollment + device attestation ─────────────────
echo ""
echo "→ [4/5] Enrollment + device attestation..."

configure_device_verification

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
        echo "    $CLI_NAME models download <id>"
    else
        echo "  Run interactively to pick a starter model:"
        echo "    curl -fsSL $COORD_URL/install.sh | bash -s"
        echo "  Or list the catalog with:  $CLI_NAME models catalog"
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
echo "  Installed: $PROVIDER_LABEL v$VERSION in $INSTALL_DIR"
echo "  Command:   $CLI_NAME"
echo ""
echo "  Next steps:"
echo "    $CLI_NAME doctor             # verify the system is ready"
echo "    $CLI_NAME models catalog     # browse available models"
echo "    $CLI_NAME models download <id>"
echo "    $CLI_NAME login              # link this Mac to your account"
echo "    $CLI_NAME start              # serve inference (interactive picker)"
echo ""
