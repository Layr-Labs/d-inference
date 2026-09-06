#!/bin/bash
# Shell-only installer behavior tests. No Swift/C build, real provider, real
# install, or real signature qualification. The signed suite shares fixtures.
set -euo pipefail
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/darkbloom-nested-install.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
"$REPO_ROOT/scripts/sync-install-embed.sh" check
CLT_SHIMS="$ROOT/shims"
mkdir -p "$CLT_SHIMS"
export DARKBLOOM_NESTED_SIGNATURE_LOG="$ROOT/signature.log"
export DARKBLOOM_NESTED_SMOKE_LOG="$ROOT/smoke.log"
cat > "$CLT_SHIMS/codesign" <<'MOCK'
#!/bin/bash
set -eu
printf '%s\n' "$*" >> "$DARKBLOOM_NESTED_SIGNATURE_LOG"
# This is deliberately a mock: cryptographic qualification belongs to the
# default atomic suite and the parent's real signed-release qualification.
if [ "${1:-}" = --verify ] && [ -n "${DARKBLOOM_NESTED_REJECT_SIGNATURE:-}" ]; then
    case "${!#}" in
        */Contents/Helpers/DarkbloomProvider.app) exit 1 ;;
    esac
fi
exit 0
MOCK
chmod 0755 "$CLT_SHIMS/codesign"
for tool in swift swiftc clang gcc xcrun sudo launchctl open; do
    printf '#!/bin/bash\necho "forbidden in shell fixture: %s" >&2\nexit 72\n' "$tool" > "$CLT_SHIMS/$tool"
    chmod 0755 "$CLT_SHIMS/$tool"
done
export PATH="$CLT_SHIMS:$PATH"
FAN_HELPER_REQUIREMENT=fixture-only

cat > "$ROOT/legacy" <<'BIN'
#!/bin/bash
exit 0
BIN
cat > "$ROOT/paged" <<'BIN'
#!/bin/bash
# engine_v2_kv_backend
set -eu
[ "${1:-}" = runtime-smoke ] || exit 91
[ "${DARKBLOOM_GEMMA4_PREFILL_CHUNK_EVAL:-}" = 18 ]
[ "${MLX_GEMMA4_FUSED_WEIGHTED_UNSORT:-}" = 1 ]
[ "${MLX_GATHER_QMM_EXPERT_SLICES:-}" = 1 ]
resolved=$(/usr/bin/perl -MCwd=abs_path -e 'print abs_path($ARGV[0])' "$0")
contents=$(dirname "$(dirname "$resolved")")
[ -s "$contents/Resources/mlx-swift-lm_MLXLMCommon.bundle/pagedattention.metal" ]
[ -s "$contents/MacOS/mlx.metallib" ]
printf '%s\n' "$resolved" >> "$DARKBLOOM_NESTED_SMOKE_LOG"
BIN
chmod 0755 "$ROOT/legacy" "$ROOT/paged"

make_shell_artifact() {
    local output=$1
    local stage="$ROOT/shell-stage"
    local app="$stage/Darkbloom.app"
    mkdir -p "$app/Contents/MacOS" "$stage/bin" \
        "$app/Contents/Resources/darkbloom-runtime-capabilities" \
        "$app/Contents/Resources/mlx-swift-lm_MLXLMCommon.bundle"
    install -m 0755 "$ROOT/paged" "$app/Contents/MacOS/darkbloom"
    install -m 0755 "$ROOT/legacy" "$app/Contents/MacOS/darkbloom-enclave"
    printf 'metal\n' > "$app/Contents/MacOS/mlx.metallib"
    chmod 0644 "$app/Contents/MacOS/mlx.metallib"
    printf '1\n' > "$app/Contents/Resources/darkbloom-runtime-capabilities/paged-kernel-v1"
    printf 'kernel\n' > "$app/Contents/Resources/mlx-swift-lm_MLXLMCommon.bundle/pagedattention.metal"
    printf 'GUI-only resource\n' > "$app/Contents/Resources/fixture-font.ttf"
    cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.darkbloom.provider</string>
<key>CFBundleExecutable</key><string>darkbloom</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>2.0.0</string>
<key>CFBundleVersion</key><string>2.0.0</string>
</dict></plist>
PLIST
    cp -p "$app/Contents/MacOS/"* "$stage/bin/"
    tar czf "$output" -C "$stage" .
    rm -rf "$stage"
}

hash_file() { shasum -a 256 "$1" | cut -d' ' -f1; }
artifact_hashes() {
    local extracted="$ROOT/hash-$RANDOM"
    mkdir -p "$extracted"
    tar xzf "$1" -C "$extracted"
    BINARY_HASH=$(hash_file "$extracted/bin/darkbloom")
    METALLIB_HASH=$(hash_file "$extracted/bin/mlx.metallib")
    rm -rf "$extracted"
}
run_install_with() {
    local installer=$1 archive=$2 install_dir=$3
    artifact_hashes "$archive"
    bash "$installer" --install-bundle-test "$archive" "$install_dir" \
        "$BINARY_HASH" "$METALLIB_HASH" "$FAN_HELPER_REQUIREMENT"
}
VALID="$ROOT/valid.tar.gz"
FLAT_LEGACY="$ROOT/flat.tar.gz"
make_shell_artifact "$VALID"
mkdir -p "$ROOT/flat/bin"
install -m 0755 "$ROOT/legacy" "$ROOT/flat/bin/darkbloom"
install -m 0755 "$ROOT/legacy" "$ROOT/flat/bin/darkbloom-enclave"
printf 'metal\n' > "$ROOT/flat/bin/mlx.metallib"
chmod 0644 "$ROOT/flat/bin/mlx.metallib"
tar czf "$FLAT_LEGACY" -C "$ROOT/flat" .
source "$REPO_ROOT/scripts/test-install-recovery-fixtures.sh"
source "$REPO_ROOT/scripts/test-install-nested-provider-fixtures.sh"
run_nested_provider_tests

# Prove nested runtime lookup was exercised, and that the additional helper
# signature verification is an effective pre-transaction gate in both copies.
grep -F '/Contents/Helpers/DarkbloomProvider.app/Contents/MacOS/darkbloom' "$DARKBLOOM_NESTED_SMOKE_LOG" >/dev/null
for installer in "$REPO_ROOT/scripts/install.sh" "$REPO_ROOT/coordinator/api/install.sh"; do
    install_dir="$ROOT/signature-rejection-$RANDOM"
    if DARKBLOOM_NESTED_REJECT_SIGNATURE=1 run_install_with "$installer" \
        "$ROOT/nested-provider.tar.gz" "$install_dir" > "$ROOT/signature-rejection.log" 2>&1; then
        echo 'nested signature rejection did not stop installation' >&2; exit 1
    fi
    grep -F 'code-signature verification failed for nested provider' "$ROOT/signature-rejection.log" >/dev/null
    test ! -e "$install_dir/Darkbloom.app"
    installer_recovery_assert_no_transaction_debris "$install_dir" 'signature rejection'
done
echo 'shell-only nested provider tests passed (codesign mocked; no signed-release qualification)'
