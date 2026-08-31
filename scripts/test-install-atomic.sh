#!/bin/bash
set -euo pipefail

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/darkbloom-install-test.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
CANONICAL_INSTALLER="$REPO_ROOT/scripts/install.sh"
EMBEDDED_INSTALLER="$REPO_ROOT/coordinator/api/install.sh"
"$REPO_ROOT/scripts/sync-install-embed.sh" check

cat > "$ROOT/main.c" <<'C'
#include <stdio.h>
static const char *fan_capability = "darkbloom-fan-helper-v1";
int main(int argc, char **argv) {
    (void)argc; (void)argv;
    fputs(fan_capability, stderr);
    return 0;
}
C
cat > "$ROOT/worker.c" <<'C'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int main(int argc, char **argv) {
    const char *gate = getenv("DARKBLOOM_SIGNED_HOST_TEST");
    if (argc != 2 || strcmp(argv[1], "--sandbox-self-test-v1") != 0
        || gate == NULL || strcmp(gate, "1") != 0) return 64;
    puts("DBXPC_SANDBOX_SELF_TEST_V1:63");
    return 0;
}
C
cat > "$ROOT/bad-worker.c" <<'C'
#include <stdio.h>
int main(void) { puts("DBXPC_SANDBOX_SELF_TEST_V1:31"); return 0; }
C
cat > "$ROOT/helper.c" <<'C'
int main(void) { return 0; }
C
clang -Os "$ROOT/main.c" -o "$ROOT/main"
clang -Os "$ROOT/worker.c" -o "$ROOT/worker"
clang -Os "$ROOT/bad-worker.c" -o "$ROOT/bad-worker"
clang -Os "$ROOT/helper.c" -o "$ROOT/helper"

CLT_SHIMS="$ROOT/clt-shims"
mkdir -p "$CLT_SHIMS"
for tool in strings otool nm xcrun swift swiftc clang gcc ld libtool lipo sudo launchctl; do
    cat > "$CLT_SHIMS/$tool" <<SHIM
#!/bin/bash
echo "xcode-select: note: no developer tools were found ($tool shim)" >&2
exit 72
SHIM
    chmod +x "$CLT_SHIMS/$tool"
done

assert_no_clt_tools() {
    local script=$1
    local offending
    offending=$(sed 's/#.*$//' "$script" \
        | grep -nEw 'strings|otool|nm|xcrun|swiftc|libtool|lipo' \
        || true)
    [ -z "$offending" ] || {
        echo "CLT-dependent tool referenced in $script:" >&2
        echo "$offending" >&2
        exit 1
    }
}

assert_no_privileged_install() {
    local script=$1
    local offending
    offending=$(sed 's/#.*$//' "$script" \
        | grep -nE '(^|[^[:alnum:]_])(sudo|launchctl)([^[:alnum:]_]|$)|/Library/PrivilegedHelperTools' \
        || true)
    [ -z "$offending" ] || {
        echo "ordinary installer contains privileged activation in $script:" >&2
        echo "$offending" >&2
        exit 1
    }
}

for installer in "$CANONICAL_INSTALLER" "$EMBEDDED_INSTALLER"; do
    assert_no_clt_tools "$installer"
    assert_no_privileged_install "$installer"
    grep -Fqx \
        'DARKBLOOM_DESIGNATED_REQUIREMENT='\''anchor apple generic and identifier "io.darkbloom.provider" and certificate leaf[subject.OU] = "SLDQ2GJ6TL"'\''' \
        "$installer"
    grep -Fqx \
        'DARKBLOOM_FAN_HELPER_REQUIREMENT='\''anchor apple generic and identifier "io.darkbloom.fan-helper" and certificate leaf[subject.OU] = "SLDQ2GJ6TL"'\''' \
        "$installer"
    grep -Fqx \
        'DARKBLOOM_WORKER_REQUIREMENT='\''anchor apple generic and identifier "io.darkbloom.provider.inference-worker" and certificate leaf[subject.OU] = "SLDQ2GJ6TL"'\''' \
        "$installer"
done

make_app_info() {
    local path=$1
    cat > "$path" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.darkbloom.install-test</string>
<key>CFBundleExecutable</key><string>darkbloom</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1.0.0</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
</dict></plist>
PLIST
}

make_artifact() {
    local output=$1
    local stage="$ROOT/stage-$RANDOM"
    local app="$stage/Darkbloom.app"
    local xpc="$app/Contents/XPCServices/DarkbloomInferenceWorker.xpc"
    mkdir -p \
        "$app/Contents/MacOS" \
        "$app/Contents/Helpers" \
        "$app/Contents/Resources/darkbloom-runtime-capabilities" \
        "$xpc/Contents/MacOS" \
        "$stage/bin"
    cp "$ROOT/main" "$app/Contents/MacOS/darkbloom"
    cp "$ROOT/main" "$app/Contents/MacOS/darkbloom-enclave"
    install -m 0755 "$ROOT/helper" "$app/Contents/Helpers/darkbloom-fan-helper"
    printf '1\n' > "$app/Contents/Resources/darkbloom-runtime-capabilities/fan-helper-v1"
    make_app_info "$app/Contents/Info.plist"

    install -m 0755 "$ROOT/worker" "$xpc/Contents/MacOS/darkbloom-inference-worker"
    cp "$ROOT/main" "$xpc/Contents/MacOS/mlx.metallib"
    cp "$REPO_ROOT/scripts/inference-worker-Info.plist" "$xpc/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 1.0.0' "$xpc/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 1.0.0' "$xpc/Contents/Info.plist"
    mkdir -p "$xpc/Contents/Resources/mlx-swift-lm_MLXLMCommon.bundle"
    printf 'kernel fixture\n' \
        > "$xpc/Contents/Resources/mlx-swift-lm_MLXLMCommon.bundle/pagedattention.metal"
    cat > "$xpc/Contents/embedded.provisionprofile" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>TeamIdentifier</key><array><string>SLDQ2GJ6TL</string></array>
<key>Entitlements</key><dict>
<key>application-identifier</key><string>SLDQ2GJ6TL.io.darkbloom.provider.inference-worker</string>
<key>keychain-access-groups</key><array><string>SLDQ2GJ6TL.io.darkbloom.provider</string></array>
<key>com.apple.security.app-sandbox</key><true/>
<key>com.apple.security.files.bookmarks.app-scope</key><true/>
</dict></dict></plist>
PLIST

    codesign --force --sign - "$xpc/Contents/MacOS/mlx.metallib"
    codesign --force --sign - \
        --identifier io.darkbloom.provider.inference-worker \
        --entitlements "$REPO_ROOT/scripts/inference-worker-entitlements.plist" \
        "$xpc/Contents/MacOS/darkbloom-inference-worker"
    codesign --force --sign - \
        --identifier io.darkbloom.provider.inference-worker \
        --entitlements "$REPO_ROOT/scripts/inference-worker-entitlements.plist" \
        "$xpc"
    codesign --force --sign - --identifier io.darkbloom.fan-helper \
        "$app/Contents/Helpers/darkbloom-fan-helper"
    codesign --force --sign - "$app/Contents/MacOS/darkbloom-enclave"
    codesign --force --sign - "$app/Contents/MacOS/darkbloom"
    codesign --force --sign - "$app"
    codesign --verify --deep --strict "$app"

    cp "$app/Contents/MacOS/darkbloom" "$stage/bin/darkbloom"
    cp "$app/Contents/MacOS/darkbloom-enclave" "$stage/bin/darkbloom-enclave"
    cp "$xpc/Contents/MacOS/mlx.metallib" "$stage/bin/mlx.metallib"
    tar czf "$output" -C "$stage" .
    rm -rf "$stage"
}

hash_file() { shasum -a 256 "$1" | cut -d' ' -f1; }
artifact_hashes() {
    local archive=$1
    local extracted="$ROOT/hash-$RANDOM"
    mkdir -p "$extracted"
    tar xzf "$archive" -C "$extracted"
    BINARY_HASH=$(hash_file "$extracted/bin/darkbloom")
    METALLIB_HASH=$(hash_file "$extracted/bin/mlx.metallib")
    rm -rf "$extracted"
}

FAN_HELPER_REQUIREMENT='identifier "io.darkbloom.fan-helper"'
WORKER_REQUIREMENT='identifier "io.darkbloom.provider.inference-worker"'
run_install() {
    local installer=$1 archive=$2 install_dir=$3
    local sandbox_probe="$ROOT/worker"
    case "$archive" in
        *bad-sandbox-probe.tar.gz) sandbox_probe="$ROOT/bad-worker" ;;
    esac
    artifact_hashes "$archive"
    PATH="$CLT_SHIMS:$PATH" bash "$installer" --install-bundle-test \
        "$archive" "$install_dir" "$BINARY_HASH" "$METALLIB_HASH" \
        "$FAN_HELPER_REQUIREMENT" "$WORKER_REQUIREMENT" "$sandbox_probe"
}

resign_outer() {
    local stage=$1
    local app="$stage/Darkbloom.app"
    codesign --force --sign - "$app"
    cp "$app/Contents/MacOS/darkbloom" "$stage/bin/darkbloom"
    cp "$app/Contents/MacOS/darkbloom-enclave" "$stage/bin/darkbloom-enclave"
}

make_variant() {
    local output=$1 mutation=$2
    local stage="$ROOT/variant-$mutation-$RANDOM"
    local app="$stage/Darkbloom.app"
    local xpc="$app/Contents/XPCServices/DarkbloomInferenceWorker.xpc"
    local worker="$xpc/Contents/MacOS/darkbloom-inference-worker"
    mkdir -p "$stage"
    tar xzf "$VALID" -C "$stage"
    local resign=1
    case "$mutation" in
        missing-xpc)
            rm -rf "$xpc"
            ;;
        missing-worker)
            rm -f "$worker"
            resign=0
            ;;
        symlink-worker)
            rm -f "$worker"
            ln -s ../../../../../MacOS/darkbloom "$worker"
            resign=0
            ;;
        wrong-identifier)
            codesign --force --sign - --identifier not.darkbloom.worker \
                --entitlements "$REPO_ROOT/scripts/inference-worker-entitlements.plist" "$worker"
            codesign --force --sign - --identifier not.darkbloom.worker \
                --entitlements "$REPO_ROOT/scripts/inference-worker-entitlements.plist" "$xpc"
            ;;
        wrong-info)
            /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier not.darkbloom.worker' \
                "$xpc/Contents/Info.plist"
            codesign --force --sign - \
                --identifier io.darkbloom.provider.inference-worker \
                --entitlements "$REPO_ROOT/scripts/inference-worker-entitlements.plist" "$xpc"
            ;;
        version-mismatch)
            /usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 9.9.9' \
                "$xpc/Contents/Info.plist"
            codesign --force --sign - \
                --identifier io.darkbloom.provider.inference-worker \
                --entitlements "$REPO_ROOT/scripts/inference-worker-entitlements.plist" "$xpc"
            ;;
        no-sandbox)
            codesign --force --sign - \
                --identifier io.darkbloom.provider.inference-worker "$worker"
            codesign --force --sign - \
                --identifier io.darkbloom.provider.inference-worker "$xpc"
            ;;
        network-entitlement)
            cp "$REPO_ROOT/scripts/inference-worker-entitlements.plist" "$ROOT/network-entitlements.plist"
            /usr/libexec/PlistBuddy -c 'Add :com.apple.security.network.client bool true' \
                "$ROOT/network-entitlements.plist"
            codesign --force --sign - \
                --identifier io.darkbloom.provider.inference-worker \
                --entitlements "$ROOT/network-entitlements.plist" "$worker"
            codesign --force --sign - \
                --identifier io.darkbloom.provider.inference-worker \
                --entitlements "$ROOT/network-entitlements.plist" "$xpc"
            ;;
        missing-metallib)
            rm -f "$xpc/Contents/MacOS/mlx.metallib"
            codesign --force --sign - \
                --identifier io.darkbloom.provider.inference-worker \
                --entitlements "$REPO_ROOT/scripts/inference-worker-entitlements.plist" "$xpc"
            ;;
        missing-paged-resource)
            rm -f "$xpc/Contents/Resources/mlx-swift-lm_MLXLMCommon.bundle/pagedattention.metal"
            codesign --force --sign - \
                --identifier io.darkbloom.provider.inference-worker \
                --entitlements "$REPO_ROOT/scripts/inference-worker-entitlements.plist" "$xpc"
            ;;
        missing-worker-profile)
            rm -f "$xpc/Contents/embedded.provisionprofile"
            codesign --force --sign - \
                --identifier io.darkbloom.provider.inference-worker \
                --entitlements "$REPO_ROOT/scripts/inference-worker-entitlements.plist" "$xpc"
            ;;
        invalid-worker-profile)
            printf 'not a profile\n' > "$xpc/Contents/embedded.provisionprofile"
            codesign --force --sign - \
                --identifier io.darkbloom.provider.inference-worker \
                --entitlements "$REPO_ROOT/scripts/inference-worker-entitlements.plist" "$xpc"
            ;;
        broad-worker-profile)
            /usr/libexec/PlistBuddy -c \
                'Set :Entitlements:application-identifier SLDQ2GJ6TL.*' \
                "$xpc/Contents/embedded.provisionprofile"
            /usr/libexec/PlistBuddy -c \
                'Add :Entitlements:keychain-access-groups:1 string SLDQ2GJ6TL.unapproved' \
                "$xpc/Contents/embedded.provisionprofile"
            codesign --force --sign - \
                --identifier io.darkbloom.provider.inference-worker \
                --entitlements "$REPO_ROOT/scripts/inference-worker-entitlements.plist" "$xpc"
            ;;
        extra-resources)
            mkdir -p "$xpc/Contents/Resources"
            printf 'unapproved\n' > "$xpc/Contents/Resources/source.txt"
            codesign --force --sign - \
                --identifier io.darkbloom.provider.inference-worker \
                --entitlements "$REPO_ROOT/scripts/inference-worker-entitlements.plist" "$xpc"
            ;;
        bad-sandbox-probe)
            cp "$ROOT/bad-worker" "$worker"
            codesign --force --sign - \
                --identifier io.darkbloom.provider.inference-worker \
                --entitlements "$REPO_ROOT/scripts/inference-worker-entitlements.plist" "$worker"
            codesign --force --sign - \
                --identifier io.darkbloom.provider.inference-worker \
                --entitlements "$REPO_ROOT/scripts/inference-worker-entitlements.plist" "$xpc"
            ;;
        tampered)
            printf 'tampered\n' >> "$worker"
            resign=0
            ;;
        *) echo "unknown variant: $mutation" >&2; exit 1 ;;
    esac
    [ "$resign" -eq 0 ] || resign_outer "$stage"
    cp "$xpc/Contents/MacOS/mlx.metallib" "$stage/bin/mlx.metallib" 2>/dev/null || true
    tar czf "$output" -C "$stage" .
    rm -rf "$stage"
}

VALID="$ROOT/valid.tar.gz"
make_artifact "$VALID"
SIGNATURE_ROOT="$ROOT/signature"
mkdir -p "$SIGNATURE_ROOT"
tar xzf "$VALID" -C "$SIGNATURE_ROOT"
SIGNED_XPC="$SIGNATURE_ROOT/Darkbloom.app/Contents/XPCServices/DarkbloomInferenceWorker.xpc"
SIGNED_WORKER="$SIGNED_XPC/Contents/MacOS/darkbloom-inference-worker"
PRODUCTION_WORKER_REQUIREMENT='anchor apple generic and identifier "io.darkbloom.provider.inference-worker" and certificate leaf[subject.OU] = "SLDQ2GJ6TL"'
for installer in "$CANONICAL_INSTALLER" "$EMBEDDED_INSTALLER"; do
    bash "$installer" --verify-worker-signature-test \
        "$SIGNED_XPC" "$SIGNED_WORKER" "$WORKER_REQUIREMENT"
    if bash "$installer" --verify-worker-signature-test \
        "$SIGNED_XPC" "$SIGNED_WORKER" "$PRODUCTION_WORKER_REQUIREMENT"
    then
        echo "$installer accepted an ad-hoc worker without the production Team ID" >&2
        exit 1
    fi
done
for mutation in \
    missing-xpc missing-worker symlink-worker wrong-identifier wrong-info \
    version-mismatch no-sandbox network-entitlement missing-metallib \
    missing-paged-resource missing-worker-profile invalid-worker-profile \
    broad-worker-profile extra-resources bad-sandbox-probe tampered
do
    make_variant "$ROOT/$mutation.tar.gz" "$mutation"
done

# A flat-only artifact is never a mature release, even if every flat binary is signed.
FLAT_ONLY_ROOT="$ROOT/flat-only"
mkdir -p "$FLAT_ONLY_ROOT"
tar xzf "$VALID" -C "$FLAT_ONLY_ROOT"
rm -rf "$FLAT_ONLY_ROOT/Darkbloom.app"
tar czf "$ROOT/flat-only.tar.gz" -C "$FLAT_ONLY_ROOT" .

# A pre-created shared-path symlink must remain untouched. Downloads happen in
# a fresh mode-0700 directory, and non-regular/multi-link archive paths fail.
ATTACKER_TMP="$ROOT/attacker-tmp"
mkdir -p "$ATTACKER_TMP"
SENTINEL="$ROOT/download-sentinel"
printf 'do-not-clobber\n' > "$SENTINEL"
ln -s "$SENTINEL" "$ATTACKER_TMP/darkbloom-bundle.tar.gz"
VALID_HASH=$(hash_file "$VALID")
for installer in "$CANONICAL_INSTALLER" "$EMBEDDED_INSTALLER"; do
    TMPDIR="$ATTACKER_TMP" bash "$installer" --secure-download-test \
        "file://$VALID" "$VALID_HASH"
    test "$(cat "$SENTINEL")" = "do-not-clobber"
    test -L "$ATTACKER_TMP/darkbloom-bundle.tar.gz"
    if bash "$installer" --verify-download-path-test \
        "$ATTACKER_TMP/darkbloom-bundle.tar.gz"
    then
        echo "$installer accepted a symlink download archive" >&2
        exit 1
    fi
    if bash "$installer" --verify-download-path-test "$ATTACKER_TMP"; then
        echo "$installer accepted a non-regular download archive" >&2
        exit 1
    fi
    ln "$VALID" "$ATTACKER_TMP/multi-link-archive"
    if bash "$installer" --verify-download-path-test "$ATTACKER_TMP/multi-link-archive"; then
        echo "$installer accepted a replaceable multi-link download archive" >&2
        exit 1
    fi
    rm -f "$ATTACKER_TMP/multi-link-archive"
done

for installer in "$CANONICAL_INSTALLER" "$EMBEDDED_INSTALLER"; do
    install_root="$ROOT/install-$(basename "$(dirname "$installer")")-$RANDOM"
    mkdir -p "$install_root/Darkbloom.app"
    printf 'old\n' > "$install_root/Darkbloom.app/sentinel"
    for mutation in \
        missing-xpc missing-worker symlink-worker wrong-identifier wrong-info \
        version-mismatch no-sandbox network-entitlement missing-metallib \
        missing-paged-resource missing-worker-profile invalid-worker-profile \
        broad-worker-profile extra-resources bad-sandbox-probe tampered flat-only
    do
        if run_install "$installer" "$ROOT/$mutation.tar.gz" "$install_root"; then
            echo "$installer accepted invalid worker fixture: $mutation" >&2
            exit 1
        fi
        test -f "$install_root/Darkbloom.app/sentinel"
    done

    run_install "$installer" "$VALID" "$install_root"
    test ! -f "$install_root/Darkbloom.app/sentinel"
    worker="$install_root/Darkbloom.app/Contents/XPCServices/DarkbloomInferenceWorker.xpc/Contents/MacOS/darkbloom-inference-worker"
    test -x "$worker"
    paged_resource="$install_root/Darkbloom.app/Contents/XPCServices/DarkbloomInferenceWorker.xpc/Contents/Resources/mlx-swift-lm_MLXLMCommon.bundle/pagedattention.metal"
    test -s "$paged_resource"
    test ! -L "$paged_resource"
    test -z "$(find "$(dirname "$(dirname "$paged_resource")")" -mindepth 1 \
        ! -path "$(dirname "$paged_resource")" ! -path "$paged_resource" -print -quit)"
    codesign --verify --deep --strict "$install_root/Darkbloom.app"
    codesign --verify --strict "-R=$WORKER_REQUIREMENT" "$worker"
    test "$(readlink "$install_root/bin/mlx.metallib")" = \
        '../Darkbloom.app/Contents/XPCServices/DarkbloomInferenceWorker.xpc/Contents/MacOS/mlx.metallib'
done

for installer in "$CANONICAL_INSTALLER" "$EMBEDDED_INSTALLER"; do
    flat_upgrade_root="$ROOT/flat-upgrade-$(basename "$(dirname "$installer")")-$RANDOM"
    mkdir -p "$flat_upgrade_root/bin"
    for legacy_name in \
        darkbloom darkbloom-enclave mlx.metallib eigeninference-enclave
    do
        printf 'legacy flat %s\n' "$legacy_name" \
            > "$flat_upgrade_root/bin/$legacy_name"
    done
    run_install "$installer" "$VALID" "$flat_upgrade_root"
    test -d "$flat_upgrade_root/Darkbloom.app"
    for migrated_name in \
        darkbloom darkbloom-enclave mlx.metallib eigeninference-enclave
    do
        test -L "$flat_upgrade_root/bin/$migrated_name"
    done
    test "$(readlink "$flat_upgrade_root/bin/mlx.metallib")" = \
        '../Darkbloom.app/Contents/XPCServices/DarkbloomInferenceWorker.xpc/Contents/MacOS/mlx.metallib'
done

seed_previous_launcher_set() {
    local root=$1
    mkdir -p "$root/bin"
    ln -s old-darkbloom "$root/bin/darkbloom"
    ln -s old-enclave "$root/bin/darkbloom-enclave"
    ln -s ../old/mlx.metallib "$root/bin/mlx.metallib"
    ln -s old-enclave-alias "$root/bin/eigeninference-enclave"
}

assert_previous_launcher_set() {
    local root=$1
    test "$(readlink "$root/bin/darkbloom")" = old-darkbloom
    test "$(readlink "$root/bin/darkbloom-enclave")" = old-enclave
    test "$(readlink "$root/bin/mlx.metallib")" = ../old/mlx.metallib
    test "$(readlink "$root/bin/eigeninference-enclave")" = old-enclave-alias
}

ROLLBACK_SHIMS="$ROOT/rollback-shims"
mkdir -p "$ROLLBACK_SHIMS"
cat > "$ROLLBACK_SHIMS/mv" <<'SHIM'
#!/bin/bash
should_fail=0
case "${DARKBLOOM_MV_FAILURE_MODE:-}" in
    app)
        case "${1:-}:${2:-}" in
            */.install-staging.*/Darkbloom.app:*/Darkbloom.app)
                should_fail=1
                ;;
        esac
        ;;
    launcher)
        case "${1:-}:${2:-}:${3:-}" in
            -h:*/.install-transaction.*/links/eigeninference-enclave:*/bin/eigeninference-enclave)
                should_fail=1
                ;;
        esac
        ;;
esac
if [ "$should_fail" -eq 1 ] \
    && [ ! -e "$DARKBLOOM_MV_FAILURE_MARKER" ]
then
    /usr/bin/touch "$DARKBLOOM_MV_FAILURE_MARKER"
    exit 73
fi
exec /bin/mv "$@"
SHIM
chmod +x "$ROLLBACK_SHIMS/mv"

for installer in "$CANONICAL_INSTALLER" "$EMBEDDED_INSTALLER"; do
    rollback_root="$ROOT/rollback-$(basename "$(dirname "$installer")")-$RANDOM"
    marker="$rollback_root/mv-failed"
    mkdir -p "$rollback_root/Darkbloom.app"
    printf 'old\n' > "$rollback_root/Darkbloom.app/sentinel"
    seed_previous_launcher_set "$rollback_root"
    artifact_hashes "$VALID"
    if DARKBLOOM_MV_FAILURE_MODE=app \
        DARKBLOOM_MV_FAILURE_MARKER="$marker" \
        PATH="$ROLLBACK_SHIMS:$CLT_SHIMS:$PATH" \
        bash "$installer" --install-bundle-test \
            "$VALID" "$rollback_root" "$BINARY_HASH" "$METALLIB_HASH" \
            "$FAN_HELPER_REQUIREMENT" "$WORKER_REQUIREMENT" "$ROOT/worker"
    then
        echo "$installer did not propagate staged-app activation failure" >&2
        exit 1
    fi
    test -f "$marker"
    test -f "$rollback_root/Darkbloom.app/sentinel"
    assert_previous_launcher_set "$rollback_root"
    test -z "$(find "$rollback_root" -maxdepth 1 \
        \( -name '.install-transaction.*' -o -name '.install-staging.*' \) \
        -print -quit)"
done

for installer in "$CANONICAL_INSTALLER" "$EMBEDDED_INSTALLER"; do
    rollback_root="$ROOT/link-rollback-$(basename "$(dirname "$installer")")-$RANDOM"
    marker="$rollback_root/mv-failed"
    mkdir -p "$rollback_root/Darkbloom.app"
    printf 'old\n' > "$rollback_root/Darkbloom.app/sentinel"
    seed_previous_launcher_set "$rollback_root"
    artifact_hashes "$VALID"
    if DARKBLOOM_MV_FAILURE_MODE=launcher \
        DARKBLOOM_MV_FAILURE_MARKER="$marker" \
        PATH="$ROLLBACK_SHIMS:$CLT_SHIMS:$PATH" \
        bash "$installer" --install-bundle-test \
            "$VALID" "$rollback_root" "$BINARY_HASH" "$METALLIB_HASH" \
            "$FAN_HELPER_REQUIREMENT" "$WORKER_REQUIREMENT" "$ROOT/worker"
    then
        echo "$installer did not propagate partial launcher activation failure" >&2
        exit 1
    fi
    test -f "$marker"
    test -f "$rollback_root/Darkbloom.app/sentinel"
    assert_previous_launcher_set "$rollback_root"
    test -z "$(find "$rollback_root" -maxdepth 1 \
        \( -name '.install-transaction.*' -o -name '.install-staging.*' \) \
        -print -quit)"
done

echo "atomic installer worker-XPC tests passed"
