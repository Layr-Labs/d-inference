#!/usr/bin/env bash
set -euo pipefail

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/darkbloom-payload-test.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
VERIFIER="$REPO_ROOT/scripts/verify-macos-release-payload.sh"

make_fixture() {
    local app=$1
    mkdir -p \
        "$app/Contents/MacOS" \
        "$app/Contents/Helpers" \
        "$app/Contents/Resources/darkbloom-runtime-capabilities" \
        "$app/Contents/Resources/DarkbloomProvider_DarkbloomApp.bundle" \
        "$app/Contents/Resources/mlx-swift-lm_MLXLMCommon.bundle" \
        "$app/Contents/_CodeSignature"

    for executable in DarkbloomApp darkbloom darkbloom-enclave; do
        printf '#!/bin/sh\nexit 0\n' > "$app/Contents/MacOS/$executable"
        chmod 0755 "$app/Contents/MacOS/$executable"
    done
    printf '#!/bin/sh\nexit 0\n' \
        > "$app/Contents/Helpers/darkbloom-fan-helper"
    chmod 0755 "$app/Contents/Helpers/darkbloom-fan-helper"

    printf 'plist\n' > "$app/Contents/Info.plist"
    printf 'profile\n' > "$app/Contents/embedded.provisionprofile"
    printf 'signature\n' > "$app/Contents/_CodeSignature/CodeResources"
    printf 'mlx\n' > "$app/Contents/MacOS/mlx.metallib"
    printf 'font\n' > "$app/Contents/Resources/Chivo-Regular.ttf"
    printf 'font\n' > "$app/Contents/Resources/Chivo-Medium.ttf"
    printf 'shader\n' \
        > "$app/Contents/Resources/DarkbloomProvider_DarkbloomApp.bundle/default.metallib"
    printf 'paged\n' \
        > "$app/Contents/Resources/mlx-swift-lm_MLXLMCommon.bundle/pagedattention.metal"
    printf '1\n' \
        > "$app/Contents/Resources/darkbloom-runtime-capabilities/fan-helper-v1"
    printf '1\n' \
        > "$app/Contents/Resources/darkbloom-runtime-capabilities/paged-kernel-v1"
    chmod 0644 \
        "$app/Contents/Info.plist" \
        "$app/Contents/embedded.provisionprofile" \
        "$app/Contents/_CodeSignature/CodeResources" \
        "$app/Contents/MacOS/mlx.metallib" \
        "$app/Contents/Resources/Chivo-Regular.ttf" \
        "$app/Contents/Resources/Chivo-Medium.ttf" \
        "$app/Contents/Resources/DarkbloomProvider_DarkbloomApp.bundle/default.metallib" \
        "$app/Contents/Resources/mlx-swift-lm_MLXLMCommon.bundle/pagedattention.metal" \
        "$app/Contents/Resources/darkbloom-runtime-capabilities/fan-helper-v1" \
        "$app/Contents/Resources/darkbloom-runtime-capabilities/paged-kernel-v1"
    find "$app" -type d -exec chmod 0755 {} +
}

expect_rejected() {
    local name=$1
    local mutation=$2
    local app="$ROOT/$name/Darkbloom.app"
    make_fixture "$app"
    bash -c "$mutation" payload-mutation "$app"
    if "$VERIFIER" "$app"; then
        echo "invalid payload passed structural verification: $name" >&2
        exit 1
    fi
}

VALID="$ROOT/valid/Darkbloom.app"
make_fixture "$VALID"
"$VERIFIER" "$VALID"

# Mutation strings intentionally expand $1 in the child bash process.
# shellcheck disable=SC2016
expect_rejected missing \
    'rm -f "$1/Contents/MacOS/darkbloom-enclave"'
# shellcheck disable=SC2016
expect_rejected extra \
    'printf "extra\n" > "$1/Contents/MacOS/unexpected-helper"; chmod 0755 "$1/Contents/MacOS/unexpected-helper"'
# shellcheck disable=SC2016
expect_rejected extra-resource \
    'printf "extra\n" > "$1/Contents/Resources/unexpected.dat"; chmod 0644 "$1/Contents/Resources/unexpected.dat"'
# shellcheck disable=SC2016
expect_rejected symlink \
    'rm -f "$1/Contents/MacOS/darkbloom-enclave"; ln -s darkbloom "$1/Contents/MacOS/darkbloom-enclave"'
# shellcheck disable=SC2016
expect_rejected executable-mode \
    'chmod 0775 "$1/Contents/MacOS/darkbloom"'
# shellcheck disable=SC2016
expect_rejected resource-mode \
    'chmod 0755 "$1/Contents/Resources/Chivo-Regular.ttf"'
# shellcheck disable=SC2016
expect_rejected invalid-marker \
    'printf "enabled\n" > "$1/Contents/Resources/darkbloom-runtime-capabilities/fan-helper-v1"'

echo "macOS release payload structural tests passed"
