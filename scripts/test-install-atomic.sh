#!/bin/bash
set -euo pipefail

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/darkbloom-install-test.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
INSTALLER="$REPO_ROOT/scripts/install.sh"

cat > "$ROOT/paged.c" <<'C'
#include <libgen.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static const char *capability = "engine_v2_kv_backend";

int main(int argc, char **argv) {
    if (argc < 2 || strcmp(argv[1], "runtime-smoke") != 0) {
        fputs(capability, stderr);
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

clang -Os "$ROOT/paged.c" -o "$ROOT/paged"
clang -Os "$ROOT/legacy.c" -o "$ROOT/legacy"

# A pristine Mac has no Xcode Command Line Tools: /usr/bin/strings, otool,
# nm, etc. are shims that prompt/fail. Prove the installers never need them
# two ways: (1) statically — no CLT tool is referenced outside comments in
# either installer; (2) behaviorally — every install below runs with failing
# CLT shims first on PATH, so any hidden invocation aborts the install.
CLT_SHIMS="$ROOT/clt-shims"
mkdir -p "$CLT_SHIMS"
for tool in strings otool nm xcrun swift swiftc clang gcc ld libtool lipo; do
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

make_artifact() {
    local output=$1
    local capability=$2
    local include_resource=$3
    local stage="$ROOT/stage-$RANDOM"
    local app="$stage/Darkbloom.app"
    local binary="$ROOT/$capability"
    mkdir -p "$app/Contents/MacOS" "$stage/bin"
    cp "$binary" "$app/Contents/MacOS/darkbloom"
    cp "$binary" "$app/Contents/MacOS/darkbloom-enclave"
    cp "$binary" "$app/Contents/MacOS/mlx.metallib"
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

    codesign --force --sign - "$app/Contents/MacOS/mlx.metallib"
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
        "$archive" "$install_dir" "$BINARY_HASH" "$METALLIB_HASH"
}

VALID="$ROOT/valid.tar.gz"
MISSING="$ROOT/missing.tar.gz"
LEGACY="$ROOT/legacy.tar.gz"
make_artifact "$VALID" paged yes
make_artifact "$MISSING" paged no
make_artifact "$LEGACY" legacy no

INSTALL="$ROOT/install"
mkdir -p "$INSTALL/Darkbloom.app"
printf 'old\n' > "$INSTALL/Darkbloom.app/sentinel"

if run_install "$MISSING" "$INSTALL"; then
    echo "missing paged resource unexpectedly installed" >&2
    exit 1
fi
test -f "$INSTALL/Darkbloom.app/sentinel"

run_install "$VALID" "$INSTALL"
test ! -f "$INSTALL/Darkbloom.app/sentinel"
DARKBLOOM_NO_UPDATE_CHECK=1 "$INSTALL/bin/darkbloom" runtime-smoke

LEGACY_INSTALL="$ROOT/legacy-install"
run_install "$LEGACY" "$LEGACY_INSTALL"
test -x "$LEGACY_INSTALL/bin/darkbloom"

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
if run_install "$MISSING" "$COORD_INSTALL"; then
    echo "coordinator installer accepted missing paged resource" >&2
    exit 1
fi
test -f "$COORD_INSTALL/Darkbloom.app/sentinel"
run_install "$VALID" "$COORD_INSTALL"
test ! -f "$COORD_INSTALL/Darkbloom.app/sentinel"

echo "atomic installer tests passed"
