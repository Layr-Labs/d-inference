#!/bin/bash
set -euo pipefail

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/darkbloom-install-test.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
INSTALLER="$REPO_ROOT/scripts/install.sh"
"$REPO_ROOT/scripts/sync-install-embed.sh" check

wait_for_file() {
    local path=$1
    local label=$2
    local attempts=${3:-200}
    local attempt
    for ((attempt = 0; attempt < attempts; attempt++)); do
        [ -f "$path" ] && return 0
        sleep 0.05
    done
    echo "timed out waiting for $label: $path" >&2
    return 1
}

process_is_active() {
    local pid=$1
    kill -0 "$pid" 2>/dev/null || return 1
    local state
    state=$(ps -p "$pid" -o stat= 2>/dev/null | tr -d '[:space:]')
    case "$state" in
        ""|*Z*) return 1 ;;
        *) return 0 ;;
    esac
}

wait_for_process_exit() {
    local pid=$1
    local label=$2
    local attempts=${3:-200}
    local attempt
    for ((attempt = 0; attempt < attempts; attempt++)); do
        process_is_active "$pid" || return 0
        sleep 0.05
    done
    echo "$label remained active after bounded termination (pid $pid)" >&2
    return 1
}

signal_exact_pids() {
    local signal=$1
    shift
    local pid
    for pid in "$@"; do
        [[ "$pid" =~ ^[1-9][0-9]*$ ]] || continue
        kill "-$signal" "$pid" 2>/dev/null || true
    done
}

assert_no_lock_helpers() {
    local temporary_dir=$1
    local helper
    for helper in "$temporary_dir"/darkbloom-install-lock.*; do
        [ -e "$helper" ] || [ -L "$helper" ] || continue
        echo "installer left generated lock helper behind: $helper" >&2
        return 1
    done
}

assert_portable_setpgid_checks() {
    local installer=$1
    local offending
    offending=$(grep -nE \
        'POSIX::setpgid\([^;]*(==|!=)[[:space:]]*0' \
        "$installer" || true)
    if [ -n "$offending" ]; then
        echo "$installer numerically checks the non-portable setpgid return:" >&2
        echo "$offending" >&2
        return 1
    fi
}

test_install_lock_signal_exit() {
    local installer=$1
    local label=$2
    local install_dir="$ROOT/signal-lock-$label"
    local temporary_dir="$install_dir/tmp"
    local entered="$install_dir/entered"
    local release="$install_dir/release"
    local after="$install_dir/after"
    mkdir -p "$install_dir" "$temporary_dir"

    TMPDIR="$temporary_dir" bash "$installer" \
        --hold-install-lock-test "$install_dir" "$entered" "$release" "$after" &
    local holder_pid=$!
    if ! wait_for_file "$entered" "installation lock probe"; then
        signal_exact_pids KILL "$holder_pid"
        wait "$holder_pid" 2>/dev/null || true
        return 1
    fi

    if TMPDIR="$temporary_dir" DARKBLOOM_INSTALL_LOCK_TIMEOUT=1 \
        bash "$installer" --recover-install-transactions-test "$install_dir"
    then
        signal_exact_pids KILL "$holder_pid"
        wait "$holder_pid" 2>/dev/null || true
        echo "$installer body ran without holding its kernel lock" >&2
        return 1
    fi
    test ! -e "$after"

    kill -TERM "$holder_pid"
    local status=0
    wait "$holder_pid" || status=$?
    test "$status" -eq 143
    test ! -e "$after"

    TMPDIR="$temporary_dir" \
        bash "$installer" --recover-install-transactions-test "$install_dir"
    test -f "$install_dir/.app-install.lock"
    test ! -L "$install_dir/.app-install.lock"
    test -f "$install_dir/recovery/update.lock"
    test ! -L "$install_dir/recovery/update.lock"
    assert_no_lock_helpers "$temporary_dir"
}

test_install_lock_startup_term() {
    local installer=$1
    local label=$2
    local install_dir="$ROOT/startup-term-$label"
    local temporary_dir="$install_dir/tmp"
    local startup_ready="$install_dir/startup-ready"
    local startup_release="$install_dir/startup-release"
    local entered="$install_dir/entered"
    local release="$install_dir/release"
    local after="$install_dir/after"
    mkdir -p "$install_dir" "$temporary_dir"

    TMPDIR="$temporary_dir" \
    DARKBLOOM_INSTALL_TEST_STARTUP_READY="$startup_ready" \
    DARKBLOOM_INSTALL_TEST_STARTUP_RELEASE="$startup_release" \
        bash "$installer" --hold-install-lock-test \
            "$install_dir" "$entered" "$release" "$after" &
    local wrapper_pid=$!
    if ! wait_for_file "$startup_ready" "lock-owner startup publication" \
        || ! wait_for_file "$entered" "startup mutation probe"
    then
        signal_exact_pids TERM "$wrapper_pid"
        wait "$wrapper_pid" 2>/dev/null || true
        return 1
    fi

    local owner_pid
    IFS= read -r owner_pid < "$startup_ready"
    kill -TERM "$wrapper_pid"
    local status=0
    wait "$wrapper_pid" || status=$?
    test "$status" -eq 143
    wait_for_process_exit "$owner_pid" "startup lock owner"
    test ! -e "$after"

    TMPDIR="$temporary_dir" DARKBLOOM_INSTALL_LOCK_TIMEOUT=2 \
        bash "$installer" --recover-install-transactions-test "$install_dir"
    assert_no_lock_helpers "$temporary_dir"
}

test_install_lock_parent_death() {
    local installer=$1
    local label=$2
    local install_dir="$ROOT/parent-death-$label"
    local temporary_dir="$install_dir/tmp"
    local owner_pid_file="$install_dir/owner.pid"
    local body_pid_file="$install_dir/body.pid"
    local descendant_pid_file="$install_dir/descendant.pid"
    local entered="$install_dir/entered"
    local mutation="$install_dir/mutation"
    mkdir -p "$install_dir" "$temporary_dir"

    TMPDIR="$temporary_dir" \
    DARKBLOOM_INSTALL_TEST_OWNER_PID_FILE="$owner_pid_file" \
        bash "$installer" --hold-stubborn-install-lock-test \
            "$install_dir" "$entered" "$body_pid_file" \
            "$descendant_pid_file" "$mutation" &
    local wrapper_pid=$!
    if ! wait_for_file "$owner_pid_file" "lock owner PID" \
        || ! wait_for_file "$body_pid_file" "locked body PID" \
        || ! wait_for_file "$descendant_pid_file" "mutation descendant PID" \
        || ! wait_for_file "$entered" "stubborn mutation probe" \
        || ! wait_for_file "$mutation" "mutation output"
    then
        signal_exact_pids TERM "$wrapper_pid"
        wait "$wrapper_pid" 2>/dev/null || true
        return 1
    fi

    local owner_pid
    local body_pid
    local descendant_pid
    IFS= read -r owner_pid < "$owner_pid_file"
    IFS= read -r body_pid < "$body_pid_file"
    IFS= read -r descendant_pid < "$descendant_pid_file"
    local body_group
    local descendant_group
    body_group=$(ps -p "$body_pid" -o pgid= | tr -d '[:space:]')
    descendant_group=$(ps -p "$descendant_pid" -o pgid= | tr -d '[:space:]')
    test "$body_group" = "$body_pid"
    test "$descendant_group" = "$body_pid"

    kill -KILL "$wrapper_pid"
    local status=0
    wait "$wrapper_pid" 2>/dev/null || status=$?
    test "$status" -eq 137

    if ! wait_for_process_exit "$owner_pid" "orphaned lock owner" \
        || ! wait_for_process_exit "$body_pid" "orphaned locked body" \
        || ! wait_for_process_exit \
            "$descendant_pid" "orphaned mutation descendant"
    then
        signal_exact_pids KILL "$owner_pid" "$body_pid" "$descendant_pid"
        return 1
    fi

    local mutation_size
    local settled_size
    mutation_size=$(wc -c < "$mutation" | tr -d '[:space:]')
    sleep 0.2
    settled_size=$(wc -c < "$mutation" | tr -d '[:space:]')
    test "$settled_size" = "$mutation_size"

    TMPDIR="$temporary_dir" DARKBLOOM_INSTALL_LOCK_TIMEOUT=3 \
        bash "$installer" --recover-install-transactions-test "$install_dir"
    assert_no_lock_helpers "$temporary_dir"
}

test_install_lock_descriptor_isolation() {
    local installer=$1
    local label=$2
    local install_dir="$ROOT/lock-descriptor-$label"
    local temporary_dir="$install_dir/tmp"
    local child_pid_file="$install_dir/child.pid"
    mkdir -p "$install_dir" "$temporary_dir"

    TMPDIR="$temporary_dir" bash "$installer" \
        --spawn-under-install-lock-test "$install_dir" "$child_pid_file"
    local child_pid
    IFS= read -r child_pid < "$child_pid_file"
    if ! process_is_active "$child_pid"; then
        echo "$installer did not leave the descriptor probe alive" >&2
        return 1
    fi

    if ! TMPDIR="$temporary_dir" DARKBLOOM_INSTALL_LOCK_TIMEOUT=1 \
        bash "$installer" --recover-install-transactions-test "$install_dir"
    then
        signal_exact_pids TERM "$child_pid"
        echo "$installer leaked its kernel lock into a descendant" >&2
        return 1
    fi
    signal_exact_pids TERM "$child_pid"
    wait_for_process_exit "$child_pid" "descriptor probe"
    assert_no_lock_helpers "$temporary_dir"
}

run_install_lock_lifecycle_tests() {
    local installer
    local label
    for label in source embedded; do
        if [ "$label" = source ]; then
            installer="$REPO_ROOT/scripts/install.sh"
        else
            installer="$REPO_ROOT/coordinator/api/install.sh"
        fi
        assert_portable_setpgid_checks "$installer"
        test_install_lock_signal_exit "$installer" "$label"
        test_install_lock_startup_term "$installer" "$label"
        test_install_lock_parent_death "$installer" "$label"
        test_install_lock_descriptor_isolation "$installer" "$label"
    done
}

case "${1:-}" in
    "") ;;
    --lock-only) ;;
    *)
        echo "usage: $0 [--lock-only]" >&2
        exit 64
        ;;
esac
run_install_lock_lifecycle_tests
if [ "${1:-}" = "--lock-only" ]; then
    echo "installer lock lifecycle tests passed"
    exit 0
fi

cat > "$ROOT/paged.c" <<'C'
#include <libgen.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static const char *capability = "engine_v2_kv_backend";
static const char *fan_capability = "darkbloom-fan-helper-v1";

int main(int argc, char **argv) {
    if (argc < 2 || strcmp(argv[1], "runtime-smoke") != 0) {
        fputs(capability, stderr);
        fputs(fan_capability, stderr);
        return 0;
    }
    const char *chunk_eval = getenv("DARKBLOOM_GEMMA4_PREFILL_CHUNK_EVAL");
    const char *weighted = getenv("MLX_GEMMA4_FUSED_WEIGHTED_UNSORT");
    const char *safe_r1 = getenv("MLX_GATHER_QMM_EXPERT_SLICES");
    if (chunk_eval == NULL || strcmp(chunk_eval, "18") != 0) return 4;
    if (weighted == NULL || strcmp(weighted, "1") != 0) return 5;
    if (safe_r1 == NULL || strcmp(safe_r1, "1") != 0) return 6;

    char resolved[PATH_MAX];
    if (realpath(argv[0], resolved) == NULL) return 2;
    char first[PATH_MAX], second[PATH_MAX], third[PATH_MAX];
    snprintf(first, sizeof(first), "%s", resolved);
    snprintf(second, sizeof(second), "%s", dirname(first));
    snprintf(third, sizeof(third), "%s", dirname(second));
    char *app = dirname(third);
    char resource[PATH_MAX];
    snprintf(
        resource, sizeof(resource),
        "%s/Contents/Resources/mlx-swift-lm_MLXLMCommon.bundle/pagedattention.metal",
        app);
    return access(resource, R_OK) == 0 ? 0 : 3;
}
C

cat > "$ROOT/legacy.c" <<'C'
int main(void) { return 0; }
C

cat > "$ROOT/fan-helper.c" <<'C'
int main(void) { return 0; }
C

clang -Os "$ROOT/paged.c" -o "$ROOT/paged"
clang -Os "$ROOT/legacy.c" -o "$ROOT/legacy"
clang -Os "$ROOT/fan-helper.c" -o "$ROOT/fan-helper"

# A pristine Mac has no Xcode Command Line Tools: /usr/bin/strings, otool,
# nm, etc. are shims that prompt/fail. Prove the installers never need them
# two ways: (1) statically — no CLT tool is referenced outside comments in
# either installer; (2) behaviorally — every install below runs with failing
# CLT shims first on PATH, so any hidden invocation aborts the install.
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
    if [ -n "$offending" ]; then
        echo "CLT-dependent tool referenced in $script:" >&2
        echo "$offending" >&2
        exit 1
    fi
}
assert_no_clt_tools "$REPO_ROOT/scripts/install.sh"
assert_no_clt_tools "$REPO_ROOT/coordinator/api/install.sh"

assert_no_privileged_install() {
    local script=$1
    local offending
    offending=$(sed 's/#.*$//' "$script" \
        | grep -nE '(^|[^[:alnum:]_])(sudo|launchctl)([^[:alnum:]_]|$)|/Library/PrivilegedHelperTools' \
        || true)
    if [ -n "$offending" ]; then
        echo "ordinary installer contains privileged activation in $script:" >&2
        echo "$offending" >&2
        exit 1
    fi
}
assert_no_privileged_install "$REPO_ROOT/scripts/install.sh"
assert_no_privileged_install "$REPO_ROOT/coordinator/api/install.sh"

make_artifact() {
    local output=$1
    local capability=$2
    local include_resource=$3
    local include_fan=${4:-no}
    local version=${5:-2.0.0}
    local stage="$ROOT/stage-$RANDOM"
    local app="$stage/Darkbloom.app"
    local binary="$ROOT/$capability"
    mkdir -p "$app/Contents/MacOS" "$stage/bin"
    install -m 0755 "$binary" "$app/Contents/MacOS/darkbloom"
    install -m 0755 "$binary" "$app/Contents/MacOS/darkbloom-enclave"
    install -m 0644 "$binary" "$app/Contents/MacOS/mlx.metallib"
    cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.darkbloom.provider</string>
<key>CFBundleExecutable</key><string>darkbloom</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>$version</string>
</dict></plist>
PLIST

    if [ "$capability" = "paged" ]; then
        mkdir -p "$app/Contents/Resources/darkbloom-runtime-capabilities"
        printf '1\n' \
            > "$app/Contents/Resources/darkbloom-runtime-capabilities/paged-kernel-v1"
        if [ "$include_resource" = "yes" ]; then
            mkdir -p "$app/Contents/Resources/mlx-swift-lm_MLXLMCommon.bundle"
            printf 'kernel\n' \
                > "$app/Contents/Resources/mlx-swift-lm_MLXLMCommon.bundle/pagedattention.metal"
        fi
    fi

    if [ "$include_fan" = "yes" ]; then
        mkdir -p \
            "$app/Contents/Helpers" \
            "$app/Contents/Resources/darkbloom-runtime-capabilities"
        install -m 0755 \
            "$ROOT/fan-helper" \
            "$app/Contents/Helpers/darkbloom-fan-helper"
        printf '1\n' \
            > "$app/Contents/Resources/darkbloom-runtime-capabilities/fan-helper-v1"
        codesign --force --sign - \
            --identifier io.darkbloom.fan-helper \
            "$app/Contents/Helpers/darkbloom-fan-helper"
    fi

    codesign --force --sign - "$app/Contents/MacOS/mlx.metallib"
    codesign --force --sign - "$app/Contents/MacOS/darkbloom-enclave"
    codesign --force --sign - "$app/Contents/MacOS/darkbloom"
    codesign --force --sign - "$app"
    codesign --verify --deep --strict "$app"

    install -m 0755 "$app/Contents/MacOS/darkbloom" "$stage/bin/darkbloom"
    install -m 0755 \
        "$app/Contents/MacOS/darkbloom-enclave" \
        "$stage/bin/darkbloom-enclave"
    install -m 0644 "$app/Contents/MacOS/mlx.metallib" "$stage/bin/mlx.metallib"
    tar czf "$output" -C "$stage" .
    rm -rf "$stage"
}

make_flat_artifact() {
    local output=$1
    local stage="$ROOT/flat-stage-$RANDOM"
    mkdir -p "$stage/bin"
    install -m 0755 "$ROOT/legacy" "$stage/bin/darkbloom"
    install -m 0755 "$ROOT/legacy" "$stage/bin/darkbloom-enclave"
    install -m 0644 "$ROOT/legacy" "$stage/bin/mlx.metallib"
    codesign --force --sign - "$stage/bin/mlx.metallib"
    codesign --force --sign - "$stage/bin/darkbloom-enclave"
    codesign --force --sign - "$stage/bin/darkbloom"
    tar czf "$output" -C "$stage" .
    rm -rf "$stage"
}

hash_file() {
    shasum -a 256 "$1" | cut -d' ' -f1
}

artifact_hashes() {
    local archive=$1
    local extracted="$ROOT/hash-$RANDOM"
    mkdir -p "$extracted"
    tar xzf "$archive" -C "$extracted"
    BINARY_HASH=$(hash_file "$extracted/bin/darkbloom")
    METALLIB_HASH=$(hash_file "$extracted/bin/mlx.metallib")
    rm -rf "$extracted"
}

run_install() {
    local archive=$1
    local install_dir=$2
    run_install_with "$INSTALLER" "$archive" "$install_dir"
}

run_install_with() {
    local installer=$1
    local archive=$2
    local install_dir=$3
    artifact_hashes "$archive"
    PATH="$CLT_SHIMS:$PATH" bash "$installer" --install-bundle-test \
        "$archive" "$install_dir" "$BINARY_HASH" "$METALLIB_HASH" \
        "$FAN_HELPER_REQUIREMENT"
}

run_install_with_restrictive_umask() {
    local installer=$1
    local archive=$2
    local install_dir=$3
    artifact_hashes "$archive"
    (
        umask 077
        PATH="$CLT_SHIMS:$PATH" bash "$installer" --install-bundle-test \
            "$archive" "$install_dir" "$BINARY_HASH" "$METALLIB_HASH" \
            "$FAN_HELPER_REQUIREMENT"
    )
}

run_install_without_hashes() {
    PATH="$CLT_SHIMS:$PATH" bash "$INSTALLER" --install-bundle-test \
        "$1" "$2" "" "" "$FAN_HELPER_REQUIREMENT"
}

VALID="$ROOT/valid.tar.gz"
OLDER="$ROOT/older.tar.gz"
NEWEST="$ROOT/newest.tar.gz"
MISSING="$ROOT/missing.tar.gz"
LEGACY="$ROOT/legacy.tar.gz"
FLAT_LEGACY="$ROOT/flat-legacy.tar.gz"
make_artifact "$VALID" paged yes yes 2.0.0
make_artifact "$OLDER" paged yes yes 1.0.0
make_artifact "$NEWEST" paged yes yes 3.0.0
make_artifact "$MISSING" paged no yes 2.0.0
make_artifact "$LEGACY" legacy no no 2.0.0
make_flat_artifact "$FLAT_LEGACY"

# The designated requirement must be applied to the complete app target,
# whose main-executable signature seals Contents/Resources.
SIGNATURE_ROOT="$ROOT/signature"
mkdir -p "$SIGNATURE_ROOT"
tar xzf "$VALID" -C "$SIGNATURE_ROOT"
APP_REQUIREMENT=$(codesign -d -r- \
    "$SIGNATURE_ROOT/Darkbloom.app" 2>&1 \
    | awk -F' => ' '/designated/{print $2; exit}')
[ -n "$APP_REQUIREMENT" ]
FAN_HELPER_REQUIREMENT=$(codesign -d -r- \
    "$SIGNATURE_ROOT/Darkbloom.app/Contents/Helpers/darkbloom-fan-helper" 2>&1 \
    | awk -F' => ' '/designated/{print $2; exit}')
[ -n "$FAN_HELPER_REQUIREMENT" ]
PRODUCTION_REQUIREMENT='anchor apple generic and identifier "io.darkbloom.provider" and certificate leaf[subject.OU] = "SLDQ2GJ6TL"'
PRODUCTION_FAN_REQUIREMENT='anchor apple generic and identifier "io.darkbloom.fan-helper" and certificate leaf[subject.OU] = "SLDQ2GJ6TL"'
for installer in \
    "$REPO_ROOT/scripts/install.sh" \
    "$REPO_ROOT/coordinator/api/install.sh"
do
    grep -Fqx \
        "DARKBLOOM_DESIGNATED_REQUIREMENT='$PRODUCTION_REQUIREMENT'" \
        "$installer"
    grep -Fqx \
        "DARKBLOOM_FAN_HELPER_REQUIREMENT='$PRODUCTION_FAN_REQUIREMENT'" \
        "$installer"
    bash "$installer" --verify-staged-app-signature-test \
        "$SIGNATURE_ROOT/Darkbloom.app" "$APP_REQUIREMENT"
    if bash "$installer" --verify-staged-app-signature-test \
        "$SIGNATURE_ROOT/Darkbloom.app" 'identifier "not.darkbloom"'
    then
        echo "$installer accepted an app outside the required identity" >&2
        exit 1
    fi
done

for installer in \
    "$REPO_ROOT/scripts/install.sh" \
    "$REPO_ROOT/coordinator/api/install.sh"
do
    restrictive_install="$ROOT/restrictive-$(basename "$(dirname "$installer")")"
    run_install_with_restrictive_umask \
        "$installer" "$VALID" "$restrictive_install"
    bash "$installer" --verify-release-payload-modes-test \
        "$restrictive_install/Darkbloom.app/Contents/MacOS" \
        "Restrictive-umask app payload"
done

# Both public installer copies accept exactly SemVer 2 and implement the
# specification's prerelease precedence without integer overflow.
VALID_SEMVERS=(
    "0.0.0"
    "1.2.3-alpha+001"
    "1.0.0-alpha.1"
    "1.0.0-0.3.7"
    "1.0.0-x.7.z.92+build.01"
    "184467440737095516160.0.1"
    "1.0.0-184467440737095516160"
)
INVALID_SEMVERS=(
    ""
    "v1.0.0"
    "1.0"
    "01.0.0"
    "1.01.0"
    "1.0.01"
    "1.0.0-"
    "1.0.0-alpha..1"
    "1.0.0-alpha.01"
    "1.0.0+"
    "1.0.0+build+second"
    "1.0.0-alpha_beta"
    "1.0.0-é"
)
SEMVER_PRECEDENCE=(
    "1.0.0-alpha"
    "1.0.0-alpha.1"
    "1.0.0-alpha.beta"
    "1.0.0-beta"
    "1.0.0-beta.2"
    "1.0.0-beta.11"
    "1.0.0-rc.1"
    "1.0.0"
)
for installer in \
    "$REPO_ROOT/scripts/install.sh" \
    "$REPO_ROOT/coordinator/api/install.sh"
do
    for version in "${VALID_SEMVERS[@]}"; do
        bash "$installer" --semver-test "$version"
    done
    for version in "${INVALID_SEMVERS[@]}"; do
        if bash "$installer" --semver-test "$version"; then
            echo "$installer accepted invalid SemVer: $version" >&2
            exit 1
        fi
    done
    for ((index = 0; index + 1 < ${#SEMVER_PRECEDENCE[@]}; index++)); do
        lower=${SEMVER_PRECEDENCE[$index]}
        higher=${SEMVER_PRECEDENCE[$((index + 1))]}
        bash "$installer" --semver-older-test "$lower" "$higher"
        if bash "$installer" --semver-older-test "$higher" "$lower"; then
            echo "$installer reversed SemVer precedence: $higher < $lower" >&2
            exit 1
        fi
    done
    if bash "$installer" \
        --semver-older-test "1.0.0+build.1" "1.0.0+build.2"
    then
        echo "$installer treated build metadata as precedence" >&2
        exit 1
    fi
    for locale_name in C en_US.UTF-8 tr_TR.UTF-8; do
        LC_ALL="$locale_name" locale >/dev/null 2>&1 || continue
        LC_ALL="$locale_name" \
            bash "$installer" --semver-test "1.0.0-alpha.1"
        if LC_ALL="$locale_name" \
            bash "$installer" --semver-test "1.0.0-é"
        then
            echo "$installer accepted non-ASCII SemVer under $locale_name" >&2
            exit 1
        fi
        LC_ALL="$locale_name" bash "$installer" \
            --semver-older-test "1.0.0-beta.2" "1.0.0-beta.11"
    done
done

test_user_app_shortcut() {
    local installer=$1
    local label=$2
    local fixture="$ROOT/shortcut-$label"
    local managed="$fixture/home/.darkbloom/Darkbloom.app"
    local applications="$fixture/home/Applications"
    local shortcut="$applications/Darkbloom.app"
    mkdir -p "$managed"

    bash "$installer" --ensure-user-app-shortcut-test "$managed" "$shortcut"
    test -L "$shortcut"
    test "$(readlink "$shortcut")" = "$managed"
    bash "$installer" --ensure-user-app-shortcut-test "$managed" "$shortcut"
    test "$(readlink "$shortcut")" = "$managed"

    rm "$shortcut"
    printf 'foreign file\n' > "$shortcut"
    bash "$installer" --ensure-user-app-shortcut-test "$managed" "$shortcut"
    test ! -L "$shortcut"
    test "$(cat "$shortcut")" = "foreign file"

    rm "$shortcut"
    mkdir -p "$shortcut"
    printf 'foreign app\n' > "$shortcut/sentinel"
    bash "$installer" --ensure-user-app-shortcut-test "$managed" "$shortcut"
    test ! -L "$shortcut"
    test "$(cat "$shortcut/sentinel")" = "foreign app"

    rm -rf "$shortcut"
    local foreign_target="$fixture/Foreign.app"
    mkdir -p "$foreign_target"
    printf 'foreign symlink target\n' > "$foreign_target/sentinel"
    ln -s "$foreign_target" "$shortcut"
    bash "$installer" --ensure-user-app-shortcut-test "$managed" "$shortcut"
    test -L "$shortcut"
    test "$(readlink "$shortcut")" = "$foreign_target"
    test "$(cat "$foreign_target/sentinel")" = "foreign symlink target"
}

test_user_app_shortcut "$REPO_ROOT/scripts/install.sh" source
test_user_app_shortcut "$REPO_ROOT/coordinator/api/install.sh" embedded

test_shell_refuses_app_relocation_journal() {
    local installer=$1
    local label=$2
    local install_dir="$ROOT/app-relocation-pending-$label"
    local shell_stage="$install_dir/.install-staging-123-456-789"
    mkdir -p "$shell_stage"
    printf 'shell-stage-must-remain\n' > "$shell_stage/sentinel"
    printf '{"schema":1}\n' \
        > "$install_dir/.app-relocation-transaction.json"

    if bash "$installer" \
        --recover-install-transactions-test "$install_dir"
    then
        echo "$installer ignored a pending app relocation journal" >&2
        exit 1
    fi
    test "$(cat "$shell_stage/sentinel")" = "shell-stage-must-remain"
    test "$(cat "$install_dir/.app-relocation-transaction.json")" \
        = '{"schema":1}'
}

test_shell_refuses_app_relocation_journal \
    "$REPO_ROOT/scripts/install.sh" source
test_shell_refuses_app_relocation_journal \
    "$REPO_ROOT/coordinator/api/install.sh" embedded

test_shell_refuses_self_update_candidate() {
    local installer=$1
    local label=$2
    local install_dir="$ROOT/self-update-candidate-$label"
    local state="$install_dir/recovery/state.json"
    mkdir -p "$install_dir/recovery"

    printf '{"schema":1,"candidate":null}\n' > "$state"
    bash "$installer" \
        --recover-install-transactions-test "$install_dir"

    printf '{"schema":1,"candidate":{"release":{"version":"2.0.0"}}}\n' \
        > "$state"
    if bash "$installer" \
        --recover-install-transactions-test "$install_dir"
    then
        echo "$installer ignored a committed SelfUpdater candidate" >&2
        return 1
    fi
    test "$(cat "$state")" \
        = '{"schema":1,"candidate":{"release":{"version":"2.0.0"}}}'

    printf 'not-json\n' > "$state"
    if bash "$installer" \
        --recover-install-transactions-test "$install_dir"
    then
        echo "$installer accepted malformed SelfUpdater state" >&2
        return 1
    fi
    test "$(cat "$state")" = "not-json"
}

test_shell_refuses_self_update_candidate \
    "$REPO_ROOT/scripts/install.sh" source
test_shell_refuses_self_update_candidate \
    "$REPO_ROOT/coordinator/api/install.sh" embedded

write_existing_bundle() {
    local app=$1
    local bundle_id=$2
    local version=${3:-1.0.0}
    mkdir -p "$app/Contents"
    cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$bundle_id</string>
<key>CFBundleExecutable</key><string>darkbloom</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>$version</string>
</dict></plist>
PLIST
    printf 'existing\n' > "$app/sentinel"
}

assert_one_foreign_copy() {
    local install_dir=$1
    shopt -s nullglob
    local copies=("$install_dir"/Darkbloom.app.foreign-*)
    if [ "${#copies[@]}" -ne 1 ]; then
        echo "expected one preserved foreign item in $install_dir, found ${#copies[@]}" >&2
        exit 1
    fi
    PRESERVED_FOREIGN=${copies[0]}
}

# A real foreign bundle is moved aside, never deleted or merged into the new
# app. The same rule covers malformed regular files and symlinks without
# following them into user-owned content elsewhere.
FOREIGN_INSTALL="$ROOT/foreign-install"
write_existing_bundle "$FOREIGN_INSTALL/Darkbloom.app" com.example.foreign
run_install "$VALID" "$FOREIGN_INSTALL"
assert_one_foreign_copy "$FOREIGN_INSTALL"
test -f "$PRESERVED_FOREIGN/sentinel"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
    "$PRESERVED_FOREIGN/Contents/Info.plist")" = "com.example.foreign"
test -x "$FOREIGN_INSTALL/Darkbloom.app/Contents/MacOS/darkbloom"

FILE_INSTALL="$ROOT/file-install"
mkdir -p "$FILE_INSTALL"
printf 'foreign regular file\n' > "$FILE_INSTALL/Darkbloom.app"
run_install "$VALID" "$FILE_INSTALL"
assert_one_foreign_copy "$FILE_INSTALL"
test "$(cat "$PRESERVED_FOREIGN")" = "foreign regular file"
test -d "$FILE_INSTALL/Darkbloom.app"

SYMLINK_INSTALL="$ROOT/symlink-install"
SYMLINK_TARGET="$ROOT/symlink-target"
mkdir -p "$SYMLINK_INSTALL" "$SYMLINK_TARGET"
printf 'outside content\n' > "$SYMLINK_TARGET/sentinel"
ln -s "$SYMLINK_TARGET" "$SYMLINK_INSTALL/Darkbloom.app"
run_install "$VALID" "$SYMLINK_INSTALL"
assert_one_foreign_copy "$SYMLINK_INSTALL"
test -L "$PRESERVED_FOREIGN"
test "$(cat "$SYMLINK_TARGET/sentinel")" = "outside content"
test -d "$SYMLINK_INSTALL/Darkbloom.app"
test ! -L "$SYMLINK_INSTALL/Darkbloom.app"

assert_foreign_restored_after_failure() {
    local installer=$1
    local label=$2
    local fault_point=$3
    local install_dir="$ROOT/foreign-rollback-$label-$fault_point"
    local destination="$install_dir/Darkbloom.app"
    local bin_dir="$install_dir/bin"

    write_existing_bundle "$destination" com.example.foreign
    printf 'foreign payload\n' > "$destination/foreign-payload"
    mkdir -p "$bin_dir"
    printf 'previous darkbloom\n' > "$bin_dir/darkbloom"
    printf 'previous metallib\n' > "$bin_dir/mlx.metallib"
    ln -s ../previous-enclave "$bin_dir/darkbloom-enclave"
    ln -s previous-legacy-enclave "$bin_dir/eigeninference-enclave"

    artifact_hashes "$VALID"
    if DARKBLOOM_INSTALL_TEST_FAIL_POINT="$fault_point" \
        PATH="$CLT_SHIMS:$PATH" \
        bash "$installer" --install-bundle-test \
            "$VALID" "$install_dir" "$BINARY_HASH" "$METALLIB_HASH" \
            "$FAN_HELPER_REQUIREMENT"
    then
        echo "$installer ignored injected install fault $fault_point" >&2
        exit 1
    fi

    test -d "$destination"
    test ! -L "$destination"
    test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
        "$destination/Contents/Info.plist")" = "com.example.foreign"
    test "$(cat "$destination/sentinel")" = "existing"
    test "$(cat "$destination/foreign-payload")" = "foreign payload"
    test -f "$bin_dir/darkbloom"
    test ! -L "$bin_dir/darkbloom"
    test "$(cat "$bin_dir/darkbloom")" = "previous darkbloom"
    test -f "$bin_dir/mlx.metallib"
    test ! -L "$bin_dir/mlx.metallib"
    test "$(cat "$bin_dir/mlx.metallib")" = "previous metallib"
    test -L "$bin_dir/darkbloom-enclave"
    test "$(readlink "$bin_dir/darkbloom-enclave")" = "../previous-enclave"
    test -L "$bin_dir/eigeninference-enclave"
    test "$(readlink "$bin_dir/eigeninference-enclave")" = "previous-legacy-enclave"

    shopt -s nullglob
    local preserved=("$install_dir"/Darkbloom.app.foreign-*)
    local backups=("$install_dir"/.install-backup-*)
    local staging=("$install_dir"/.install-staging-*)
    test "${#preserved[@]}" -eq 0
    test "${#backups[@]}" -eq 0
    test "${#staging[@]}" -eq 0
}

# The first fault lands before the staged app move. The second lands after the
# first managed symlink has already changed, proving rollback restores both the
# exact foreign bundle and partially-mutated managed links. Exercise canonical
# and coordinator-embedded installers; sync parity alone must not hide runtime
# transaction drift.
for installer_label in source embedded; do
    if [ "$installer_label" = "source" ]; then
        fault_installer="$REPO_ROOT/scripts/install.sh"
    else
        fault_installer="$REPO_ROOT/coordinator/api/install.sh"
    fi
    assert_foreign_restored_after_failure \
        "$fault_installer" "$installer_label" staged-app-move
    assert_foreign_restored_after_failure \
        "$fault_installer" "$installer_label" link-darkbloom-enclave
done

source "$REPO_ROOT/scripts/test-install-recovery-fixtures.sh"

assert_interrupted_app_transaction_recovers() {
    local installer=$1
    local label=$2
    local crash_point=$3
    local expected=$4
    local install_dir="$ROOT/crash-recovery-$label-$crash_point"
    local destination="$install_dir/Darkbloom.app"
    local bin_dir="$install_dir/bin"

    write_existing_bundle "$destination" com.example.foreign
    printf 'foreign payload\n' > "$destination/foreign-payload"
    mkdir -p "$bin_dir"
    printf 'previous darkbloom\n' > "$bin_dir/darkbloom"
    printf 'previous metallib\n' > "$bin_dir/mlx.metallib"
    ln -s ../previous-enclave "$bin_dir/darkbloom-enclave"
    ln -s previous-legacy-enclave "$bin_dir/eigeninference-enclave"

    installer_recovery_expect_install_crash \
        "$installer" "$VALID" "$install_dir" "$crash_point"

    bash "$installer" --recover-install-transactions-test "$install_dir"
    installer_recovery_assert_no_transaction_debris \
        "$install_dir" "interrupted app transaction recovery"
    local preserved_count=0
    local preserved_path=""
    local candidate
    for candidate in "$install_dir"/Darkbloom.app.foreign-*; do
        if [ -e "$candidate" ] || [ -L "$candidate" ]; then
            preserved_count=$((preserved_count + 1))
            preserved_path=$candidate
        fi
    done

    if [ "$expected" = "rollback" ]; then
        test "$preserved_count" -eq 0
        test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
            "$destination/Contents/Info.plist")" = "com.example.foreign"
        test "$(cat "$destination/foreign-payload")" = "foreign payload"
        test -f "$bin_dir/darkbloom"
        test ! -L "$bin_dir/darkbloom"
        test "$(cat "$bin_dir/darkbloom")" = "previous darkbloom"
        test -L "$bin_dir/darkbloom-enclave"
        test "$(readlink "$bin_dir/darkbloom-enclave")" = "../previous-enclave"
        test -L "$bin_dir/eigeninference-enclave"
        test "$(readlink "$bin_dir/eigeninference-enclave")" = \
            "previous-legacy-enclave"
    else
        test "$preserved_count" -eq 1
        test -f "$preserved_path/foreign-payload"
        test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
            "$destination/Contents/Info.plist")" = "io.darkbloom.provider"
        test -L "$bin_dir/darkbloom"
        test "$(readlink "$bin_dir/darkbloom")" = \
            "../Darkbloom.app/Contents/MacOS/darkbloom"
        test -L "$bin_dir/eigeninference-enclave"
        test "$(readlink "$bin_dir/eigeninference-enclave")" = \
            "darkbloom-enclave"
    fi
}

for crash_point in \
    staging-created \
    transaction-prepared \
    previous-app-moved \
    previous-bin-moved \
    staged-app-moved \
    managed-links-installed
do
    assert_interrupted_app_transaction_recovers \
        "$REPO_ROOT/scripts/install.sh" source "$crash_point" rollback
done
assert_interrupted_app_transaction_recovers \
    "$REPO_ROOT/scripts/install.sh" source app-transaction-committed committed
assert_interrupted_app_transaction_recovers \
    "$REPO_ROOT/scripts/install.sh" source transaction-retired committed
assert_interrupted_app_transaction_recovers \
    "$REPO_ROOT/coordinator/api/install.sh" embedded staged-app-moved rollback
assert_interrupted_app_transaction_recovers \
    "$REPO_ROOT/coordinator/api/install.sh" embedded app-transaction-committed committed

assert_recovery_is_restart_safe() {
    local installer=$1
    local label=$2
    local install_dir="$ROOT/recovery-restart-$label"
    local destination="$install_dir/Darkbloom.app"
    local bin_dir="$install_dir/bin"

    write_existing_bundle "$destination" com.example.foreign
    printf 'foreign payload\n' > "$destination/foreign-payload"
    mkdir -p "$bin_dir"
    printf 'previous darkbloom\n' > "$bin_dir/darkbloom"
    printf 'previous metallib\n' > "$bin_dir/mlx.metallib"
    ln -s ../previous-enclave "$bin_dir/darkbloom-enclave"
    ln -s previous-legacy-enclave "$bin_dir/eigeninference-enclave"

    installer_recovery_expect_install_crash \
        "$installer" "$VALID" "$install_dir" staged-app-moved
    installer_recovery_expect_recovery_crash \
        "$installer" "$install_dir" recovery-app-restored

    bash "$installer" --recover-install-transactions-test "$install_dir"
    test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
        "$destination/Contents/Info.plist")" = "com.example.foreign"
    test "$(cat "$destination/foreign-payload")" = "foreign payload"
    test "$(cat "$bin_dir/darkbloom")" = "previous darkbloom"
    test "$(cat "$bin_dir/mlx.metallib")" = "previous metallib"
    installer_recovery_assert_no_transaction_debris \
        "$install_dir" "restart-safe recovery"
    local debris
    for debris in "$install_dir"/*.interrupted-*; do
        if [ -e "$debris" ] || [ -L "$debris" ]; then
            echo "restart-safe recovery left unexpected debris: $debris" >&2
            exit 1
        fi
    done
}

test_path_identity() {
    stat -c '%d:%i' "$1" 2>/dev/null \
        || stat -f '%d:%i' "$1" 2>/dev/null
}

assert_fresh_recovery_rejects_replacement() {
    local installer=$1
    local label=$2
    local kind=$3
    local install_dir="$ROOT/fresh-replacement-$label-$kind"
    local destination
    local archive
    local crash_point
    if [ "$kind" = "app" ]; then
        destination="$install_dir/Darkbloom.app"
        archive=$VALID
        crash_point=staged-app-moved
    else
        destination="$install_dir/bin"
        archive=$FLAT_LEGACY
        crash_point=flat-layout-moved
    fi

    installer_recovery_expect_install_crash \
        "$installer" "$archive" "$install_dir" "$crash_point"

    local displaced="$ROOT/fresh-replacement-original-$label-$kind"
    mv "$destination" "$displaced"
    mkdir -p "$destination"
    printf 'unrelated replacement\n' > "$destination/foreign-payload"
    local replacement_identity
    replacement_identity=$(test_path_identity "$destination")

    local attempt
    for attempt in 1 2; do
        if bash "$installer" \
            --recover-install-transactions-test "$install_dir"
        then
            echo "$installer accepted a replacement $kind root" >&2
            return 1
        fi
        test "$(test_path_identity "$destination")" = "$replacement_identity"
        test "$(cat "$destination/foreign-payload")" = \
            "unrelated replacement"
        test -e "$displaced"
        shopt -s nullglob
        local backups=("$install_dir"/.install-backup-*)
        test "${#backups[@]}" -eq 1
        test -f "${backups[0]}/.transaction"
    done
}

assert_recovery_is_restart_safe "$REPO_ROOT/scripts/install.sh" source
assert_recovery_is_restart_safe \
    "$REPO_ROOT/coordinator/api/install.sh" embedded
for replacement_label in source embedded; do
    if [ "$replacement_label" = source ]; then
        replacement_installer="$REPO_ROOT/scripts/install.sh"
    else
        replacement_installer="$REPO_ROOT/coordinator/api/install.sh"
    fi
    assert_fresh_recovery_rejects_replacement \
        "$replacement_installer" "$replacement_label" app
    assert_fresh_recovery_rejects_replacement \
        "$replacement_installer" "$replacement_label" flat
done

assert_fresh_recovery_removes_partial_candidate() {
    local installer=$1
    local label=$2
    local install_dir="$ROOT/partial-fresh-candidate-$label"
    local destination="$install_dir/Darkbloom.app"

    installer_recovery_expect_install_crash \
        "$installer" "$VALID" "$install_dir" staged-app-moved

    local candidate_identity
    candidate_identity=$(test_path_identity "$destination")
    rm -f "$destination/Contents/MacOS/darkbloom"
    test "$(test_path_identity "$destination")" = "$candidate_identity"
    bash "$installer" --recover-install-transactions-test "$install_dir"
    test ! -e "$destination"
    test ! -L "$destination"
    shopt -s nullglob
    local preserved=("$install_dir"/Darkbloom.app.interrupted-*)
    test "${#preserved[@]}" -eq 1
    test ! -e "${preserved[0]}/Contents/MacOS/darkbloom"
    bash "$installer" --recover-install-transactions-test "$install_dir"
    local backups=("$install_dir"/.install-backup-*)
    test "${#backups[@]}" -eq 0
    test -e "${preserved[0]}"
    installer_recovery_assert_no_transaction_debris \
        "$install_dir" "partial fresh candidate recovery"
}

assert_recovery_preserves_mutated_candidate_and_restores_previous() {
    local installer=$1
    local label=$2
    local install_dir="$ROOT/mutated-candidate-with-previous-$label"
    local destination="$install_dir/Darkbloom.app"
    write_existing_bundle "$destination" com.example.foreign

    installer_recovery_expect_install_crash \
        "$installer" "$VALID" "$install_dir" staged-app-moved

    printf 'created after crash\n' > "$destination/created-after-crash"
    bash "$installer" --recover-install-transactions-test "$install_dir"
    test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
        "$destination/Contents/Info.plist")" = "com.example.foreign"

    shopt -s nullglob
    local preserved=("$install_dir"/Darkbloom.app.interrupted-*)
    test "${#preserved[@]}" -eq 1
    test "$(cat "${preserved[0]}/created-after-crash")" = \
        "created after crash"
    installer_recovery_assert_no_transaction_debris \
        "$install_dir" "mutated candidate recovery"
}

for mutation_label in source embedded; do
    if [ "$mutation_label" = source ]; then
        mutation_installer="$REPO_ROOT/scripts/install.sh"
    else
        mutation_installer="$REPO_ROOT/coordinator/api/install.sh"
    fi
    assert_fresh_recovery_removes_partial_candidate \
        "$mutation_installer" "$mutation_label"
    assert_recovery_preserves_mutated_candidate_and_restores_previous \
        "$mutation_installer" "$mutation_label"
done

assert_unpaired_installer_tree_survives() {
    local installer=$1
    local label=$2
    local kind=$3
    local install_dir="$ROOT/unpaired-$kind-$label"
    local transaction_id=123-456-789
    local debris="$install_dir/.install-$kind-$transaction_id"
    mkdir -p "$debris"
    printf 'unrelated %s\n' "$kind" > "$debris/sentinel"
    local debris_identity
    debris_identity=$(test_path_identity "$debris")

    if bash "$installer" \
        --recover-install-transactions-test "$install_dir"
    then
        echo "$installer accepted unpaired $kind debris" >&2
        return 1
    fi
    test "$(test_path_identity "$debris")" = "$debris_identity"
    test "$(cat "$debris/sentinel")" = "unrelated $kind"
}

assert_replaced_staging_survives_and_owned_staging_retires() {
    local installer=$1
    local label=$2
    local kind=$3
    local install_dir="$ROOT/replaced-staging-$kind-$label"
    local archive
    if [ "$kind" = app ]; then
        archive=$VALID
    else
        archive=$FLAT_LEGACY
    fi

    installer_recovery_expect_install_crash \
        "$installer" "$archive" "$install_dir" transaction-prepared
    local backup
    backup=$(installer_recovery_only_backup "$install_dir")
    installer_recovery_assert_manifest_phase "$backup" prepared
    local transaction_id=${backup##*/.install-backup-}
    local stage="$install_dir/.install-staging-$transaction_id"
    local ownership="$install_dir/.install-ownership-$transaction_id"
    test -d "$stage"
    test -f "$ownership"

    local owned_stage="$ROOT/replaced-staging-owned-$kind-$label"
    local unrelated_stage="$ROOT/replaced-staging-unrelated-$kind-$label"
    mv "$stage" "$owned_stage"
    mkdir "$stage"
    printf 'same-name unrelated staging\n' > "$stage/sentinel"
    local replacement_identity
    replacement_identity=$(test_path_identity "$stage")

    if bash "$installer" \
        --recover-install-transactions-test "$install_dir"
    then
        echo "$installer deleted a replacement staging tree" >&2
        return 1
    fi
    test "$(test_path_identity "$stage")" = "$replacement_identity"
    test "$(cat "$stage/sentinel")" = "same-name unrelated staging"
    installer_recovery_assert_manifest_phase "$backup" rolled_back

    mv "$stage" "$unrelated_stage"
    mv "$owned_stage" "$stage"
    bash "$installer" --recover-install-transactions-test "$install_dir"
    test "$(cat "$unrelated_stage/sentinel")" = \
        "same-name unrelated staging"
    installer_recovery_assert_no_transaction_debris \
        "$install_dir" "$kind replacement staging recovery"
}

installer_recovery_only_garbage() {
    local install_dir=$1
    local garbage=()
    local candidate
    for candidate in "$install_dir"/.install-garbage-*; do
        if [ -e "$candidate" ] || [ -L "$candidate" ]; then
            garbage+=("$candidate")
        fi
    done
    [ "${#garbage[@]}" -eq 1 ] || {
        echo "expected one retired transaction in $install_dir, found ${#garbage[@]}" >&2
        return 1
    }
    printf '%s\n' "${garbage[0]}"
}

assert_retirement_preserves_preexisting_garbage() {
    local installer=$1
    local label=$2
    local kind=$3
    local recovery_kind=$4
    local install_dir="$ROOT/retirement-collision-$kind-$recovery_kind-$label"
    local archive
    local crash_point
    local expected_phase
    if [ "$kind" = app ]; then
        archive=$VALID
        crash_point='staged-app-moved'
    else
        archive=$FLAT_LEGACY
        crash_point='flat-layout-moved'
    fi
    if [ "$recovery_kind" = committed ]; then
        if [ "$kind" = app ]; then
            crash_point='app-transaction-committed'
        else
            crash_point='flat-transaction-committed'
        fi
        expected_phase=committed
    else
        expected_phase=rolled_back
    fi

    installer_recovery_expect_install_crash \
        "$installer" "$archive" "$install_dir" "$crash_point"
    local backup
    backup=$(installer_recovery_only_backup "$install_dir")
    if [ "$recovery_kind" = committed ]; then
        installer_recovery_assert_manifest_phase "$backup" committed
    else
        installer_recovery_assert_manifest_phase "$backup" prepared
    fi
    local transaction_id=${backup##*/.install-backup-}
    local garbage_path="$install_dir/.install-garbage-$transaction_id"
    local unrelated_garbage="$ROOT/retirement-collision-unrelated-$kind-$recovery_kind-$label"
    mkdir "$garbage_path"
    printf 'preexisting unrelated garbage\n' > "$garbage_path/sentinel"
    local garbage_identity
    garbage_identity=$(test_path_identity "$garbage_path")

    if bash "$installer" \
        --recover-install-transactions-test "$install_dir"
    then
        echo "$installer replaced preexisting garbage during retirement" >&2
        return 1
    fi
    test "$(test_path_identity "$garbage_path")" = "$garbage_identity"
    test "$(cat "$garbage_path/sentinel")" = "preexisting unrelated garbage"
    installer_recovery_assert_manifest_phase "$backup" "$expected_phase"

    mv "$garbage_path" "$unrelated_garbage"
    bash "$installer" --recover-install-transactions-test "$install_dir"
    test "$(cat "$unrelated_garbage/sentinel")" = \
        "preexisting unrelated garbage"
    installer_recovery_assert_no_transaction_debris \
        "$install_dir" "$kind $recovery_kind retirement collision recovery"
}

assert_replaced_garbage_survives_and_owned_garbage_retires() {
    local installer=$1
    local label=$2
    local kind=$3
    local recovery_kind=$4
    local install_dir="$ROOT/replaced-garbage-$kind-$recovery_kind-$label"
    local archive
    local interrupted_point
    if [ "$kind" = app ]; then
        archive=$VALID
        interrupted_point=staged-app-moved
    else
        archive=$FLAT_LEGACY
        interrupted_point=flat-layout-moved
    fi

    if [ "$recovery_kind" = committed ]; then
        installer_recovery_expect_install_crash \
            "$installer" "$archive" "$install_dir" transaction-retired
    else
        installer_recovery_expect_install_crash \
            "$installer" "$archive" "$install_dir" "$interrupted_point"
        local interrupted_backup
        interrupted_backup=$(installer_recovery_only_backup "$install_dir")
        installer_recovery_assert_manifest_phase \
            "$interrupted_backup" prepared
        installer_recovery_expect_recovery_crash \
            "$installer" "$install_dir" transaction-retired
    fi

    local garbage_path
    garbage_path=$(installer_recovery_only_garbage "$install_dir")
    local expected_phase=committed
    if [ "$recovery_kind" = interrupted ]; then
        expected_phase=rolled_back
    fi
    installer_recovery_assert_manifest_phase "$garbage_path" "$expected_phase"
    local transaction_id=${garbage_path##*/.install-garbage-}
    test -f "$install_dir/.install-ownership-$transaction_id"

    local owned_garbage="$ROOT/replaced-garbage-owned-$kind-$recovery_kind-$label"
    local unrelated_garbage="$ROOT/replaced-garbage-unrelated-$kind-$recovery_kind-$label"
    mv "$garbage_path" "$owned_garbage"
    mkdir "$garbage_path"
    printf 'same-name unrelated garbage\n' > "$garbage_path/sentinel"
    local replacement_identity
    replacement_identity=$(test_path_identity "$garbage_path")

    if bash "$installer" \
        --recover-install-transactions-test "$install_dir"
    then
        echo "$installer deleted a replacement garbage tree" >&2
        return 1
    fi
    test "$(test_path_identity "$garbage_path")" = "$replacement_identity"
    test "$(cat "$garbage_path/sentinel")" = "same-name unrelated garbage"
    installer_recovery_assert_manifest_phase \
        "$owned_garbage" "$expected_phase"

    mv "$garbage_path" "$unrelated_garbage"
    mv "$owned_garbage" "$garbage_path"
    bash "$installer" --recover-install-transactions-test "$install_dir"
    test "$(cat "$unrelated_garbage/sentinel")" = \
        "same-name unrelated garbage"
    installer_recovery_assert_no_transaction_debris \
        "$install_dir" "$kind $recovery_kind replacement garbage recovery"
}

assert_committed_foreign_recovery_requires_previous_identity() {
    local installer=$1
    local label=$2
    local install_dir="$ROOT/foreign-identity-$label"
    local destination="$install_dir/Darkbloom.app"
    write_existing_bundle "$destination" com.example.foreign-identity
    printf 'journaled previous app\n' > "$destination/previous-only"

    installer_recovery_expect_install_crash \
        "$installer" "$VALID" "$install_dir" app-transaction-committed
    local backup
    backup=$(installer_recovery_only_backup "$install_dir")
    installer_recovery_assert_manifest_phase "$backup" committed
    local transaction_id=${backup##*/.install-backup-}
    local preserved_path="$install_dir/Darkbloom.app.foreign-$transaction_id"
    mv "$backup/Darkbloom.app" "$preserved_path"
    local previous_identity
    previous_identity=$(test_path_identity "$preserved_path")

    local journaled_previous="$ROOT/foreign-identity-owned-$label"
    local unrelated_previous="$ROOT/foreign-identity-unrelated-$label"
    mv "$preserved_path" "$journaled_previous"
    mkdir "$preserved_path"
    printf 'same-name unrelated foreign app\n' > "$preserved_path/sentinel"
    local replacement_identity
    replacement_identity=$(test_path_identity "$preserved_path")

    if bash "$installer" \
        --recover-install-transactions-test "$install_dir"
    then
        echo "$installer accepted an unrelated committed foreign app" >&2
        return 1
    fi
    test "$(test_path_identity "$preserved_path")" = "$replacement_identity"
    test "$(cat "$preserved_path/sentinel")" = \
        "same-name unrelated foreign app"
    installer_recovery_assert_manifest_phase "$backup" committed

    mv "$preserved_path" "$unrelated_previous"
    mv "$journaled_previous" "$preserved_path"
    test "$(test_path_identity "$preserved_path")" = "$previous_identity"
    bash "$installer" --recover-install-transactions-test "$install_dir"
    test "$(cat "$preserved_path/previous-only")" = "journaled previous app"
    test "$(cat "$unrelated_previous/sentinel")" = \
        "same-name unrelated foreign app"
    installer_recovery_assert_no_transaction_debris \
        "$install_dir" "committed foreign identity recovery"
}

assert_unpaired_installer_tree_survives \
    "$REPO_ROOT/scripts/install.sh" source staging
assert_unpaired_installer_tree_survives \
    "$REPO_ROOT/coordinator/api/install.sh" embedded garbage
assert_replaced_staging_survives_and_owned_staging_retires \
    "$REPO_ROOT/scripts/install.sh" source app
assert_replaced_staging_survives_and_owned_staging_retires \
    "$REPO_ROOT/coordinator/api/install.sh" embedded flat
assert_retirement_preserves_preexisting_garbage \
    "$REPO_ROOT/scripts/install.sh" source app interrupted
assert_retirement_preserves_preexisting_garbage \
    "$REPO_ROOT/coordinator/api/install.sh" embedded flat committed
assert_replaced_garbage_survives_and_owned_garbage_retires \
    "$REPO_ROOT/scripts/install.sh" source app committed
assert_replaced_garbage_survives_and_owned_garbage_retires \
    "$REPO_ROOT/coordinator/api/install.sh" embedded flat interrupted
assert_committed_foreign_recovery_requires_previous_identity \
    "$REPO_ROOT/scripts/install.sh" source
assert_committed_foreign_recovery_requires_previous_identity \
    "$REPO_ROOT/coordinator/api/install.sh" embedded

assert_committed_app_mutation_rolls_back() {
    local installer=$1
    local label=$2
    local component=$3
    local install_dir="$ROOT/committed-app-mutation-$label-$component"
    local destination="$install_dir/Darkbloom.app"
    local bin_dir="$install_dir/bin"

    write_existing_bundle "$destination" com.example.predecessor
    printf 'known-good predecessor\n' > "$destination/predecessor-payload"
    mkdir -p "$bin_dir"
    printf 'previous darkbloom\n' > "$bin_dir/darkbloom"
    printf 'previous metallib\n' > "$bin_dir/mlx.metallib"
    printf 'previous-only\n' > "$bin_dir/previous-only"
    ln -s ../previous-enclave "$bin_dir/darkbloom-enclave"
    ln -s previous-legacy-enclave "$bin_dir/eigeninference-enclave"

    installer_recovery_expect_install_crash \
        "$installer" "$VALID" "$install_dir" app-transaction-committed
    local transaction_backup
    transaction_backup=$(installer_recovery_only_backup "$install_dir")
    installer_recovery_assert_manifest_phase "$transaction_backup" committed

    local mutated_root
    local marker_path
    if [ "$component" = app ]; then
        mutated_root=$destination
        marker_path="$destination/Contents/MacOS/darkbloom"
    else
        mutated_root=$bin_dir
        marker_path="$bin_dir/same-inode-bin-mutation"
    fi
    local mutated_identity
    mutated_identity=$(test_path_identity "$mutated_root")
    if [ "$component" = app ]; then
        printf 'same-inode-app-mutation\n' >> "$marker_path"
    else
        printf 'same-inode-bin-mutation\n' > "$marker_path"
    fi
    test "$(test_path_identity "$mutated_root")" = "$mutated_identity"

    bash "$installer" --recover-install-transactions-test "$install_dir"
    test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
        "$destination/Contents/Info.plist")" = "com.example.predecessor"
    test "$(cat "$destination/predecessor-payload")" = \
        "known-good predecessor"
    test "$(cat "$bin_dir/darkbloom")" = "previous darkbloom"
    test "$(cat "$bin_dir/previous-only")" = "previous-only"

    shopt -s nullglob
    local preserved_label
    if [ "$component" = app ]; then
        preserved_label=Darkbloom.app
    else
        preserved_label=bin
    fi
    local preserved=("$install_dir/$preserved_label".interrupted-*)
    test "${#preserved[@]}" -eq 1
    if [ "$component" = app ]; then
        grep -aF "same-inode-app-mutation" \
            "${preserved[0]}/Contents/MacOS/darkbloom" >/dev/null
    else
        test "$(cat "${preserved[0]}/same-inode-bin-mutation")" = \
            "same-inode-bin-mutation"
    fi
    installer_recovery_assert_no_transaction_debris \
        "$install_dir" "committed app mutation recovery"

    bash "$installer" --recover-install-transactions-test "$install_dir"
    test "$(cat "$destination/predecessor-payload")" = \
        "known-good predecessor"
    test -e "${preserved[0]}"
}

for committed_app_label in source embedded; do
    if [ "$committed_app_label" = source ]; then
        committed_app_installer="$REPO_ROOT/scripts/install.sh"
    else
        committed_app_installer="$REPO_ROOT/coordinator/api/install.sh"
    fi
    assert_committed_app_mutation_rolls_back \
        "$committed_app_installer" "$committed_app_label" app
    assert_committed_app_mutation_rolls_back \
        "$committed_app_installer" "$committed_app_label" bin
done

assert_malformed_recovery_artifact_is_rejected() {
    local installer=$1
    local label=$2
    local artifact_kind=$3
    local install_dir="$ROOT/malformed-recovery-$label-$artifact_kind"
    local outside="$ROOT/malformed-recovery-outside-$label-$artifact_kind"
    mkdir -p "$install_dir" "$outside"
    printf 'live\n' > "$install_dir/live-sentinel"
    printf 'outside\n' > "$outside/outside-sentinel"

    case "$artifact_kind" in
        backup-file)
            printf 'not a directory\n' > \
                "$install_dir/.install-backup-123-456-789"
            ;;
        backup-symlink)
            ln -s "$outside" "$install_dir/.install-backup-123-456-789"
            ;;
        unknown-backup)
            mkdir "$install_dir/.install-backup-attacker"
            printf 'untrusted\n' > \
                "$install_dir/.install-backup-attacker/payload"
            ;;
        malformed-manifest)
            mkdir "$install_dir/.install-backup-123-456-789"
            printf 'version=2\nkind=app\n' > \
                "$install_dir/.install-backup-123-456-789/.transaction"
            ;;
        staging-symlink)
            ln -s "$outside" "$install_dir/.install-staging-123-456-789"
            ;;
        *)
            echo "unknown malformed recovery fixture: $artifact_kind" >&2
            exit 1
            ;;
    esac

    if bash "$installer" \
        --recover-install-transactions-test "$install_dir"
    then
        echo "$installer accepted malformed recovery artifact $artifact_kind" >&2
        exit 1
    fi
    test "$(cat "$install_dir/live-sentinel")" = "live"
    test "$(cat "$outside/outside-sentinel")" = "outside"
}

for malformed_label in source embedded; do
    if [ "$malformed_label" = source ]; then
        malformed_installer="$REPO_ROOT/scripts/install.sh"
    else
        malformed_installer="$REPO_ROOT/coordinator/api/install.sh"
    fi
    for artifact_kind in \
        backup-file \
        backup-symlink \
        unknown-backup \
        malformed-manifest \
        staging-symlink
    do
        assert_malformed_recovery_artifact_is_rejected \
            "$malformed_installer" "$malformed_label" "$artifact_kind"
    done
done

assert_interrupted_flat_transaction_recovers() {
    local installer=$1
    local label=$2
    local crash_point=$3
    local expected=$4
    local install_dir="$ROOT/flat-crash-recovery-$label-$crash_point"

    run_install_with "$installer" "$FLAT_LEGACY" "$install_dir"
    printf 'previous-only\n' > "$install_dir/bin/previous-only"
    installer_recovery_expect_install_crash \
        "$installer" "$FLAT_LEGACY" "$install_dir" "$crash_point"

    bash "$installer" --recover-install-transactions-test "$install_dir"
    test -x "$install_dir/bin/darkbloom"
    test -L "$install_dir/bin/eigeninference-enclave"
    if [ "$expected" = "rollback" ]; then
        test "$(cat "$install_dir/bin/previous-only")" = "previous-only"
    else
        test ! -e "$install_dir/bin/previous-only"
    fi
    installer_recovery_assert_no_transaction_debris \
        "$install_dir" "interrupted flat transaction recovery"
}

assert_interrupted_flat_transaction_recovers \
    "$REPO_ROOT/scripts/install.sh" source transaction-prepared rollback
assert_interrupted_flat_transaction_recovers \
    "$REPO_ROOT/scripts/install.sh" source flat-previous-moved rollback
assert_interrupted_flat_transaction_recovers \
    "$REPO_ROOT/scripts/install.sh" source flat-transaction-committed committed
assert_interrupted_flat_transaction_recovers \
    "$REPO_ROOT/scripts/install.sh" source transaction-retired committed
assert_interrupted_flat_transaction_recovers \
    "$REPO_ROOT/coordinator/api/install.sh" embedded flat-layout-moved rollback

# Historical journal compatibility and the recovery-only crash boundaries use
# the real signed/flat artifacts and filesystem helpers initialized above.
source "$REPO_ROOT/scripts/test-install-recovery-checkpoints.sh"
source "$REPO_ROOT/scripts/test-install-recovery-compatibility.sh"

assert_committed_flat_mutation_rolls_back() {
    local installer=$1
    local label=$2
    local install_dir="$ROOT/committed-flat-mutation-$label"
    local bin_dir="$install_dir/bin"

    run_install_with "$installer" "$FLAT_LEGACY" "$install_dir"
    printf 'known-good predecessor\n' > "$bin_dir/previous-only"
    installer_recovery_expect_install_crash \
        "$installer" "$FLAT_LEGACY" "$install_dir" \
        flat-transaction-committed
    local transaction_backup
    transaction_backup=$(installer_recovery_only_backup "$install_dir")
    installer_recovery_assert_manifest_phase "$transaction_backup" committed

    local candidate_identity
    candidate_identity=$(test_path_identity "$bin_dir")
    printf 'same-inode-flat-mutation\n' >> "$bin_dir/darkbloom"
    test "$(test_path_identity "$bin_dir")" = "$candidate_identity"

    bash "$installer" --recover-install-transactions-test "$install_dir"
    test "$(cat "$bin_dir/previous-only")" = "known-good predecessor"
    if grep -aF "same-inode-flat-mutation" \
        "$bin_dir/darkbloom" >/dev/null
    then
        echo "$installer retained the mutated committed flat candidate" >&2
        return 1
    fi

    shopt -s nullglob
    local preserved=("$install_dir/bin".interrupted-*)
    test "${#preserved[@]}" -eq 1
    grep -aF "same-inode-flat-mutation" \
        "${preserved[0]}/darkbloom" >/dev/null
    installer_recovery_assert_no_transaction_debris \
        "$install_dir" "committed flat mutation recovery"

    bash "$installer" --recover-install-transactions-test "$install_dir"
    test "$(cat "$bin_dir/previous-only")" = "known-good predecessor"
    test -e "${preserved[0]}"
}

assert_fresh_rollback_restarts_after_partial_removal() {
    local installer=$1
    local label=$2
    local kind=$3
    local component=$4
    local install_dir="$ROOT/fresh-rollback-restart-$label-$kind-$component"
    local archive
    local setup_crash
    if [ "$kind" = app ]; then
        archive=$VALID
        setup_crash="managed-links-installed"
    else
        archive=$FLAT_LEGACY
        setup_crash="flat-layout-moved"
    fi

    installer_recovery_expect_install_crash \
        "$installer" "$archive" "$install_dir" "$setup_crash"
    local candidate_path="$install_dir/bin"
    if [ "$component" = app ]; then
        candidate_path="$install_dir/Darkbloom.app"
    fi
    local candidate_identity
    candidate_identity=$(test_path_identity "$candidate_path")

    installer_recovery_expect_recovery_crash \
        "$installer" "$install_dir" "recovery-$component-removal-partial"

    shopt -s nullglob
    local transaction_backup
    transaction_backup=$(installer_recovery_only_backup "$install_dir")
    installer_recovery_assert_manifest_phase "$transaction_backup" prepared
    test -d "$transaction_backup/.rollback-$component"
    test ! -L "$transaction_backup/.rollback-$component"
    test "$(test_path_identity "$transaction_backup/.rollback-$component")" = \
        "$candidate_identity"
    if [ "$component" = app ]; then
        test ! -e \
            "$transaction_backup/.rollback-app/Contents/MacOS/darkbloom"
        test ! -e "$install_dir/Darkbloom.app"
    else
        test ! -e "$transaction_backup/.rollback-bin/darkbloom"
        test ! -e "$install_dir/bin"
    fi

    bash "$installer" --recover-install-transactions-test "$install_dir"
    test ! -e "$install_dir/Darkbloom.app"
    test ! -L "$install_dir/Darkbloom.app"
    test ! -e "$install_dir/bin"
    test ! -L "$install_dir/bin"
    installer_recovery_assert_no_transaction_debris \
        "$install_dir" "partial fresh rollback recovery"

    # A third run proves the completed recovery remains idempotent.
    bash "$installer" --recover-install-transactions-test "$install_dir"
    test ! -e "$install_dir/Darkbloom.app"
    test ! -e "$install_dir/bin"
}

for restart_label in source embedded; do
    if [ "$restart_label" = source ]; then
        restart_installer="$REPO_ROOT/scripts/install.sh"
    else
        restart_installer="$REPO_ROOT/coordinator/api/install.sh"
    fi
    assert_committed_flat_mutation_rolls_back \
        "$restart_installer" "$restart_label"
    assert_fresh_rollback_restarts_after_partial_removal \
        "$restart_installer" "$restart_label" app app
    assert_fresh_rollback_restarts_after_partial_removal \
        "$restart_installer" "$restart_label" app bin
    assert_fresh_rollback_restarts_after_partial_removal \
        "$restart_installer" "$restart_label" flat bin
done

# A legacy release has no authenticated app version and must never overwrite
# the CLI links for an installed app. Otherwise SelfUpdater continues to launch
# the app while users invoke unrelated stale flat binaries from bin/.
for installer_label in source embedded; do
    if [ "$installer_label" = "source" ]; then
        layout_installer="$REPO_ROOT/scripts/install.sh"
    else
        layout_installer="$REPO_ROOT/coordinator/api/install.sh"
    fi
    layout_install="$ROOT/flat-over-app-$installer_label"
    run_install_with "$layout_installer" "$VALID" "$layout_install"
    if run_install_with "$layout_installer" "$FLAT_LEGACY" "$layout_install"; then
        echo "$installer_label installer replaced app layout with flat release" >&2
        exit 1
    fi
    test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
        "$layout_install/Darkbloom.app/Contents/Info.plist")" = "2.0.0"
    test -L "$layout_install/bin/darkbloom"
    test "$(readlink "$layout_install/bin/darkbloom")" = \
        "../Darkbloom.app/Contents/MacOS/darkbloom"
done

# Release and unsigned-dev identifiers are the only replaceable owners. They
# are swapped in place without producing a misleading foreign backup.
for owned_id in io.darkbloom.provider dev.darkbloom.app; do
    owned_install="$ROOT/owned-${owned_id//./-}"
    if [ "$owned_id" = "io.darkbloom.provider" ]; then
        run_install "$VALID" "$owned_install"
    else
        write_existing_bundle "$owned_install/Darkbloom.app" "$owned_id"
    fi
    run_install "$VALID" "$owned_install"
    test ! -e "$owned_install/Darkbloom.app/sentinel"
    shopt -s nullglob
    owned_foreign=("$owned_install"/Darkbloom.app.foreign-*)
    test "${#owned_foreign[@]}" -eq 0
done

# A same-ID app without the pinned release signature is user-owned foreign
# content, not permission to erase it.
ADHOC_SAME_ID_INSTALL="$ROOT/ad-hoc-same-id"
write_existing_bundle \
    "$ADHOC_SAME_ID_INSTALL/Darkbloom.app" io.darkbloom.provider 9.0.0
run_install "$VALID" "$ADHOC_SAME_ID_INSTALL"
assert_one_foreign_copy "$ADHOC_SAME_ID_INSTALL"
test -f "$PRESERVED_FOREIGN/sentinel"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$PRESERVED_FOREIGN/Contents/Info.plist")" = "9.0.0"

# Every installer entry point is monotonic: a stale but correctly signed
# archive cannot replace a newer installed app.
for installer_label in source embedded; do
    if [ "$installer_label" = "source" ]; then
        version_installer="$REPO_ROOT/scripts/install.sh"
    else
        version_installer="$REPO_ROOT/coordinator/api/install.sh"
    fi
    version_install="$ROOT/version-$installer_label"
    run_install_with "$version_installer" "$VALID" "$version_install"
    if run_install_with "$version_installer" "$OLDER" "$version_install"; then
        echo "$installer_label installer accepted a signed downgrade" >&2
        exit 1
    fi
    test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
        "$version_install/Darkbloom.app/Contents/Info.plist")" = "2.0.0"
    shopt -s nullglob
    version_backups=("$version_install"/.install-backup-*)
    version_staging=("$version_install"/.install-staging-*)
    test "${#version_backups[@]}" -eq 0
    test "${#version_staging[@]}" -eq 0
done

# Competing valid installers share one destination lock. Whichever reaches the
# commit first, the final app is the highest version and no transaction debris
# remains.
CONCURRENT_INSTALL="$ROOT/concurrent-install"
run_install "$OLDER" "$CONCURRENT_INSTALL"
artifact_hashes "$VALID"
valid_binary_hash=$BINARY_HASH
valid_metallib_hash=$METALLIB_HASH
artifact_hashes "$NEWEST"
newest_binary_hash=$BINARY_HASH
newest_metallib_hash=$METALLIB_HASH
PATH="$CLT_SHIMS:$PATH" bash "$REPO_ROOT/scripts/install.sh" \
    --install-bundle-test "$VALID" "$CONCURRENT_INSTALL" \
    "$valid_binary_hash" "$valid_metallib_hash" "$FAN_HELPER_REQUIREMENT" &
valid_pid=$!
PATH="$CLT_SHIMS:$PATH" bash "$REPO_ROOT/coordinator/api/install.sh" \
    --install-bundle-test "$NEWEST" "$CONCURRENT_INSTALL" \
    "$newest_binary_hash" "$newest_metallib_hash" "$FAN_HELPER_REQUIREMENT" &
newest_pid=$!
valid_status=0
newest_status=0
wait "$valid_pid" || valid_status=$?
wait "$newest_pid" || newest_status=$?
test "$newest_status" -eq 0
[[ "$valid_status" -eq 0 || "$valid_status" -eq 1 ]]
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$CONCURRENT_INSTALL/Darkbloom.app/Contents/Info.plist")" = "3.0.0"
shopt -s nullglob
concurrent_backups=("$CONCURRENT_INSTALL"/.install-backup-*)
concurrent_staging=("$CONCURRENT_INSTALL"/.install-staging-*)
concurrent_locks=("$CONCURRENT_INSTALL"/.app-install-lock*)
test "${#concurrent_backups[@]}" -eq 0
test "${#concurrent_staging[@]}" -eq 0
test "${#concurrent_locks[@]}" -eq 0
test -f "$CONCURRENT_INSTALL/.app-install.lock"
test ! -L "$CONCURRENT_INSTALL/.app-install.lock"
test -f "$CONCURRENT_INSTALL/recovery/update.lock"
test ! -L "$CONCURRENT_INSTALL/recovery/update.lock"

make_fan_variant() {
    local output=$1
    local mutation=$2
    local stage="$ROOT/fan-variant-$mutation-$RANDOM"
    local app="$stage/Darkbloom.app"
    local helper="$app/Contents/Helpers/darkbloom-fan-helper"
    local marker="$app/Contents/Resources/darkbloom-runtime-capabilities/fan-helper-v1"
    mkdir -p "$stage"
    tar xzf "$VALID" -C "$stage"

    case "$mutation" in
        missing-helper)
            rm -f "$helper"
            ;;
        missing-marker)
            rm -f "$marker"
            ;;
        non-executable)
            chmod 0644 "$helper"
            ;;
        symlink)
            rm -f "$helper"
            ln -s ../MacOS/darkbloom "$helper"
            ;;
        wrong-identifier)
            codesign --force --sign - \
                --identifier not.darkbloom.fan-helper "$helper"
            ;;
        tampered)
            printf 'tampered\n' >> "$helper"
            ;;
        *)
            echo "unknown fan variant: $mutation" >&2
            exit 1
            ;;
    esac

    # Keep the outer app structurally valid except for the intentional tamper,
    # so each negative case exercises the dedicated fan-helper checks.
    if [ "$mutation" != "tampered" ]; then
        codesign --force --sign - "$app"
        # Re-signing the outer app may update its main executable signature.
        # Keep the release verifier's flat payload byte-identical so rejection
        # reaches the dedicated fan-helper invariant under test.
        cp "$app/Contents/MacOS/darkbloom" "$stage/bin/darkbloom"
        cp "$app/Contents/MacOS/darkbloom-enclave" "$stage/bin/darkbloom-enclave"
        cp "$app/Contents/MacOS/mlx.metallib" "$stage/bin/mlx.metallib"
    fi
    tar czf "$output" -C "$stage" .
    rm -rf "$stage"
}

FAN_MISSING_HELPER="$ROOT/fan-missing-helper.tar.gz"
FAN_MISSING_MARKER="$ROOT/fan-missing-marker.tar.gz"
FAN_NON_EXECUTABLE="$ROOT/fan-non-executable.tar.gz"
FAN_SYMLINK="$ROOT/fan-symlink.tar.gz"
FAN_WRONG_ID="$ROOT/fan-wrong-id.tar.gz"
FAN_TAMPERED="$ROOT/fan-tampered.tar.gz"
make_fan_variant "$FAN_MISSING_HELPER" missing-helper
make_fan_variant "$FAN_MISSING_MARKER" missing-marker
make_fan_variant "$FAN_NON_EXECUTABLE" non-executable
make_fan_variant "$FAN_SYMLINK" symlink
make_fan_variant "$FAN_WRONG_ID" wrong-identifier
make_fan_variant "$FAN_TAMPERED" tampered

assert_fan_variants_rejected() {
    local install_dir=$1
    for archive in \
        "$FAN_MISSING_HELPER" \
        "$FAN_MISSING_MARKER" \
        "$FAN_NON_EXECUTABLE" \
        "$FAN_SYMLINK" \
        "$FAN_WRONG_ID" \
        "$FAN_TAMPERED"
    do
        if run_install "$archive" "$install_dir"; then
            echo "invalid fan-helper artifact unexpectedly installed: $archive" >&2
            exit 1
        fi
    done
}

# Make the registered flat metallib differ from the signed app payload.
# Structural app verification alone must not admit it.
DIVERGED_ROOT="$ROOT/diverged"
mkdir -p "$DIVERGED_ROOT"
tar xzf "$VALID" -C "$DIVERGED_ROOT"
printf 'diverged\n' \
    >> "$DIVERGED_ROOT/bin/mlx.metallib"
DIVERGED="$ROOT/diverged.tar.gz"
tar czf "$DIVERGED" -C "$DIVERGED_ROOT" .

INSTALL="$ROOT/install"
mkdir -p "$INSTALL/Darkbloom.app"
printf 'old\n' > "$INSTALL/Darkbloom.app/sentinel"

assert_fan_variants_rejected "$INSTALL"
test -f "$INSTALL/Darkbloom.app/sentinel"
if run_install_without_hashes "$VALID" "$INSTALL"; then
    echo "app release without payload hashes unexpectedly installed" >&2
    exit 1
fi
test -f "$INSTALL/Darkbloom.app/sentinel"
if run_install "$MISSING" "$INSTALL"; then
    echo "missing paged resource unexpectedly installed" >&2
    exit 1
fi
test -f "$INSTALL/Darkbloom.app/sentinel"
if run_install "$DIVERGED" "$INSTALL"; then
    echo "divergent app payload unexpectedly installed" >&2
    exit 1
fi
test -f "$INSTALL/Darkbloom.app/sentinel"

run_install "$VALID" "$INSTALL"
test ! -f "$INSTALL/Darkbloom.app/sentinel"
DARKBLOOM_NO_UPDATE_CHECK=1 \
    DARKBLOOM_GEMMA4_PREFILL_CHUNK_EVAL=18 \
    MLX_GEMMA4_FUSED_WEIGHTED_UNSORT=1 \
    MLX_GATHER_QMM_EXPERT_SLICES=1 \
    "$INSTALL/bin/darkbloom" runtime-smoke
INSTALLED_FAN_HELPER="$INSTALL/Darkbloom.app/Contents/Helpers/darkbloom-fan-helper"
INSTALLED_FAN_MARKER="$INSTALL/Darkbloom.app/Contents/Resources/darkbloom-runtime-capabilities/fan-helper-v1"
test -f "$INSTALLED_FAN_HELPER"
test ! -L "$INSTALLED_FAN_HELPER"
test -x "$INSTALLED_FAN_HELPER"
test "$(stat -f '%Lp' "$INSTALLED_FAN_HELPER")" = "755"
test "$(tr -d '[:space:]' < "$INSTALLED_FAN_MARKER")" = "1"
codesign --verify --strict "-R=$FAN_HELPER_REQUIREMENT" "$INSTALLED_FAN_HELPER"

LEGACY_INSTALL="$ROOT/legacy-install"
run_install "$LEGACY" "$LEGACY_INSTALL"
test -x "$LEGACY_INSTALL/bin/darkbloom"
test ! -e "$LEGACY_INSTALL/Darkbloom.app/Contents/Helpers/darkbloom-fan-helper"

TAMPER_ROOT="$ROOT/tamper"
mkdir -p "$TAMPER_ROOT"
tar xzf "$VALID" -C "$TAMPER_ROOT"
printf 'tampered\n' \
    >> "$TAMPER_ROOT/Darkbloom.app/Contents/Resources/mlx-swift-lm_MLXLMCommon.bundle/pagedattention.metal"
TAMPERED="$ROOT/tampered.tar.gz"
tar czf "$TAMPERED" -C "$TAMPER_ROOT" .
if run_install "$TAMPERED" "$INSTALL"; then
    echo "tampered signed app unexpectedly installed" >&2
    exit 1
fi
DARKBLOOM_NO_UPDATE_CHECK=1 \
    DARKBLOOM_GEMMA4_PREFILL_CHUNK_EVAL=18 \
    MLX_GEMMA4_FUSED_WEIGHTED_UNSORT=1 \
    MLX_GATHER_QMM_EXPERT_SLICES=1 \
    "$INSTALL/bin/darkbloom" runtime-smoke

INSTALLER="$REPO_ROOT/coordinator/api/install.sh"
COORD_INSTALL="$ROOT/coordinator-install"
mkdir -p "$COORD_INSTALL/Darkbloom.app"
printf 'coordinator-old\n' > "$COORD_INSTALL/Darkbloom.app/sentinel"
assert_fan_variants_rejected "$COORD_INSTALL"
test -f "$COORD_INSTALL/Darkbloom.app/sentinel"
if run_install_without_hashes "$VALID" "$COORD_INSTALL"; then
    echo "coordinator installer accepted an app without payload hashes" >&2
    exit 1
fi
test -f "$COORD_INSTALL/Darkbloom.app/sentinel"
if run_install "$MISSING" "$COORD_INSTALL"; then
    echo "coordinator installer accepted missing paged resource" >&2
    exit 1
fi
test -f "$COORD_INSTALL/Darkbloom.app/sentinel"
if run_install "$DIVERGED" "$COORD_INSTALL"; then
    echo "coordinator installer accepted a divergent app payload" >&2
    exit 1
fi
test -f "$COORD_INSTALL/Darkbloom.app/sentinel"
run_install "$VALID" "$COORD_INSTALL"
test ! -f "$COORD_INSTALL/Darkbloom.app/sentinel"
test -x "$COORD_INSTALL/Darkbloom.app/Contents/Helpers/darkbloom-fan-helper"
test "$(stat -f '%Lp' "$COORD_INSTALL/Darkbloom.app/Contents/Helpers/darkbloom-fan-helper")" = "755"

COORD_LEGACY_INSTALL="$ROOT/coordinator-legacy-install"
run_install "$LEGACY" "$COORD_LEGACY_INSTALL"
test -x "$COORD_LEGACY_INSTALL/bin/darkbloom"
test ! -e "$COORD_LEGACY_INSTALL/Darkbloom.app/Contents/Helpers/darkbloom-fan-helper"

echo "atomic installer tests passed"
