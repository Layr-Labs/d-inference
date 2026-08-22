#!/bin/bash
set -euo pipefail

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/darkbloom-install-test.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
INSTALLER="$REPO_ROOT/scripts/install.sh"
"$REPO_ROOT/scripts/sync-install-embed.sh" check

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
    local include_baseline=${5:-yes}
    local stage="$ROOT/stage-$RANDOM"
    local app="$stage/Darkbloom.app"
    local binary="$ROOT/$capability"
    mkdir -p "$app/Contents/MacOS" "$stage/bin"
    cp "$binary" "$app/Contents/MacOS/darkbloom"
    cp "$binary" "$app/Contents/MacOS/darkbloom-enclave"
    cp "$binary" "$app/Contents/MacOS/mlx.metallib"
    if [ "$include_baseline" = "yes" ]; then
        mkdir -p \
            "$app/Contents/MacOS/Resources" \
            "$app/Contents/Resources/darkbloom-runtime-capabilities"
        printf 'baseline\n' > "$app/Contents/MacOS/Resources/mlx.metallib"
        printf '1\n' \
            > "$app/Contents/Resources/darkbloom-runtime-capabilities/baseline-metallib-v1"
    fi
    cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.darkbloom.install-test</string>
<key>CFBundleExecutable</key><string>darkbloom</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
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
    if [ "$include_baseline" = "yes" ]; then
        codesign --force --sign - "$app/Contents/MacOS/Resources/mlx.metallib"
    fi
    codesign --force --sign - "$app/Contents/MacOS/darkbloom-enclave"
    codesign --force --sign - "$app/Contents/MacOS/darkbloom"
    codesign --force --sign - "$app"
    codesign --verify --deep --strict "$app"

    cp "$app/Contents/MacOS/darkbloom" "$stage/bin/darkbloom"
    cp "$app/Contents/MacOS/darkbloom-enclave" "$stage/bin/darkbloom-enclave"
    cp "$app/Contents/MacOS/mlx.metallib" "$stage/bin/mlx.metallib"
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
    artifact_hashes "$archive"
    PATH="$CLT_SHIMS:$PATH" bash "$INSTALLER" --install-bundle-test \
        "$archive" "$install_dir" "$BINARY_HASH" "$METALLIB_HASH" \
        "$FAN_HELPER_REQUIREMENT"
}

run_install_without_hashes() {
    PATH="$CLT_SHIMS:$PATH" bash "$INSTALLER" --install-bundle-test \
        "$1" "$2" "" "" "$FAN_HELPER_REQUIREMENT"
}

VALID="$ROOT/valid.tar.gz"
MISSING="$ROOT/missing.tar.gz"
LEGACY="$ROOT/legacy.tar.gz"
PRE_BASELINE="$ROOT/pre-baseline.tar.gz"
make_artifact "$VALID" paged yes yes yes
make_artifact "$MISSING" paged no yes yes
make_artifact "$LEGACY" legacy no no no
# Releases predating the two-library layout ship neither the baseline nor its
# marker and must stay installable.
make_artifact "$PRE_BASELINE" paged yes yes no

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

make_baseline_variant() {
    local output=$1
    local mutation=$2
    local stage="$ROOT/baseline-variant-$mutation-$RANDOM"
    local app="$stage/Darkbloom.app"
    local baseline="$app/Contents/MacOS/Resources/mlx.metallib"
    local marker="$app/Contents/Resources/darkbloom-runtime-capabilities/baseline-metallib-v1"
    mkdir -p "$stage"
    tar xzf "$VALID" -C "$stage"

    case "$mutation" in
        missing-library)
            rm -f "$baseline"
            ;;
        missing-marker)
            rm -f "$marker"
            ;;
        empty-library)
            : > "$baseline"
            ;;
        bad-marker)
            printf '0\n' > "$marker"
            ;;
        symlink)
            rm -f "$baseline"
            ln -s ../mlx.metallib "$baseline"
            ;;
        *)
            echo "unknown baseline variant: $mutation" >&2
            exit 1
            ;;
    esac

    codesign --force --sign - "$app"
    cp "$app/Contents/MacOS/darkbloom" "$stage/bin/darkbloom"
    cp "$app/Contents/MacOS/darkbloom-enclave" "$stage/bin/darkbloom-enclave"
    cp "$app/Contents/MacOS/mlx.metallib" "$stage/bin/mlx.metallib"
    tar czf "$output" -C "$stage" .
    rm -rf "$stage"
}

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

BASELINE_MISSING_LIBRARY="$ROOT/baseline-missing-library.tar.gz"
BASELINE_MISSING_MARKER="$ROOT/baseline-missing-marker.tar.gz"
BASELINE_EMPTY_LIBRARY="$ROOT/baseline-empty-library.tar.gz"
BASELINE_BAD_MARKER="$ROOT/baseline-bad-marker.tar.gz"
BASELINE_SYMLINK="$ROOT/baseline-symlink.tar.gz"
make_baseline_variant "$BASELINE_MISSING_LIBRARY" missing-library
make_baseline_variant "$BASELINE_MISSING_MARKER" missing-marker
make_baseline_variant "$BASELINE_EMPTY_LIBRARY" empty-library
make_baseline_variant "$BASELINE_BAD_MARKER" bad-marker
make_baseline_variant "$BASELINE_SYMLINK" symlink

assert_baseline_variants_rejected() {
    local install_dir=$1
    for archive in \
        "$BASELINE_MISSING_LIBRARY" \
        "$BASELINE_MISSING_MARKER" \
        "$BASELINE_EMPTY_LIBRARY" \
        "$BASELINE_BAD_MARKER" \
        "$BASELINE_SYMLINK"
    do
        if run_install "$archive" "$install_dir"; then
            echo "invalid baseline-metallib artifact unexpectedly installed: $archive" >&2
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
assert_baseline_variants_rejected "$INSTALL"
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
test -s "$INSTALL/Darkbloom.app/Contents/MacOS/Resources/mlx.metallib"
test ! -L "$INSTALL/Darkbloom.app/Contents/MacOS/Resources/mlx.metallib"
DARKBLOOM_NO_UPDATE_CHECK=1 "$INSTALL/bin/darkbloom" runtime-smoke

PRE_BASELINE_INSTALL="$ROOT/pre-baseline-install"
run_install "$PRE_BASELINE" "$PRE_BASELINE_INSTALL"
test ! -e "$PRE_BASELINE_INSTALL/Darkbloom.app/Contents/MacOS/Resources/mlx.metallib"
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
DARKBLOOM_NO_UPDATE_CHECK=1 "$INSTALL/bin/darkbloom" runtime-smoke

INSTALLER="$REPO_ROOT/coordinator/api/install.sh"
COORD_INSTALL="$ROOT/coordinator-install"
mkdir -p "$COORD_INSTALL/Darkbloom.app"
printf 'coordinator-old\n' > "$COORD_INSTALL/Darkbloom.app/sentinel"
assert_fan_variants_rejected "$COORD_INSTALL"
test -f "$COORD_INSTALL/Darkbloom.app/sentinel"
assert_baseline_variants_rejected "$COORD_INSTALL"
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
