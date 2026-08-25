#!/usr/bin/env bash
set -euo pipefail

fail() {
    echo "macOS release payload verification failed: $*" >&2
    exit 1
}

[ "$#" -eq 1 ] || {
    echo "usage: $0 <Darkbloom.app>" >&2
    exit 64
}
APP=$1
[ -d "$APP" ] && [ ! -L "$APP" ] \
    || fail "artifact must be a real Darkbloom.app directory"

file_mode() {
    local target=$1
    case "$(uname)" in
        Darwin) /usr/bin/stat -f '%Lp' "$target" ;;
        *) /usr/bin/stat -c '%a' "$target" ;;
    esac
}

require_regular() {
    local path=$1
    local mode=$2
    local label=$3
    [ -f "$path" ] && [ ! -L "$path" ] \
        || fail "$label must be a regular non-symlink file"
    [ "$(file_mode "$path")" = "$mode" ] \
        || fail "$label must have mode 0$mode"
}

require_nonempty_regular() {
    require_regular "$1" "$2" "$3"
    [ -s "$1" ] || fail "$3 must not be empty"
}

child_is_allowed() {
    local child=$1
    shift
    local allowed
    for allowed in "$@"; do
        [ "$child" = "$allowed" ] && return 0
    done
    return 1
}

require_exact_children() {
    local directory=$1
    shift
    [ -d "$directory" ] && [ ! -L "$directory" ] \
        || fail "required directory is missing: $directory"
    local path
    local child
    while IFS= read -r -d '' path; do
        child=${path##*/}
        child_is_allowed "$child" "$@" \
            || fail "unexpected payload: $path"
    done < <(/usr/bin/find "$directory" -mindepth 1 -maxdepth 1 -print0)
    for child in "$@"; do
        [ -e "$directory/$child" ] || [ -L "$directory/$child" ] \
            || fail "required payload is missing: $directory/$child"
    done
}

unexpected_node=$(
    /usr/bin/find "$APP" -mindepth 1 \
        \( -type l -o \( ! -type f ! -type d \) \) \
        -print -quit
)
[ -z "$unexpected_node" ] \
    || fail "symlink or unsupported filesystem node is forbidden: $unexpected_node"

require_exact_children \
    "$APP" \
    Contents
require_exact_children \
    "$APP/Contents" \
    Helpers Info.plist MacOS Resources _CodeSignature embedded.provisionprofile
require_exact_children \
    "$APP/Contents/MacOS" \
    DarkbloomApp darkbloom darkbloom-enclave mlx.metallib
require_exact_children \
    "$APP/Contents/Helpers" \
    darkbloom-fan-helper
require_exact_children \
    "$APP/Contents/_CodeSignature" \
    CodeResources
require_exact_children \
    "$APP/Contents/Resources/darkbloom-runtime-capabilities" \
    fan-helper-v1 paged-kernel-v1

resources="$APP/Contents/Resources"
while IFS= read -r -d '' path; do
    child=${path##*/}
    case "$child" in
        Chivo-Regular.ttf|Chivo-Medium.ttf|darkbloom-runtime-capabilities)
            ;;
        *.bundle)
            [ -d "$path" ] \
                || fail "SwiftPM resource bundle must be a directory: $path"
            ;;
        *)
            fail "unexpected top-level app resource: $path"
            ;;
    esac
done < <(/usr/bin/find "$resources" -mindepth 1 -maxdepth 1 -print0)

for required_bundle in \
    DarkbloomProvider_DarkbloomApp.bundle \
    mlx-swift-lm_MLXLMCommon.bundle
do
    [ -d "$resources/$required_bundle" ] \
        || fail "required SwiftPM resource bundle is missing: $required_bundle"
done

for executable in \
    "$APP/Contents/MacOS/DarkbloomApp" \
    "$APP/Contents/MacOS/darkbloom" \
    "$APP/Contents/MacOS/darkbloom-enclave" \
    "$APP/Contents/Helpers/darkbloom-fan-helper"
do
    require_nonempty_regular "$executable" 755 "$executable"
done

while IFS= read -r -d '' file; do
    case "$file" in
        "$APP/Contents/MacOS/DarkbloomApp"|\
        "$APP/Contents/MacOS/darkbloom"|\
        "$APP/Contents/MacOS/darkbloom-enclave"|\
        "$APP/Contents/Helpers/darkbloom-fan-helper")
            ;;
        *)
            require_regular "$file" 644 "$file"
            ;;
    esac
done < <(/usr/bin/find "$APP" -type f -print0)

while IFS= read -r -d '' directory; do
    [ "$(file_mode "$directory")" = "755" ] \
        || fail "directory must have mode 0755: $directory"
done < <(/usr/bin/find "$APP" -type d -print0)

for resource in \
    "$APP/Contents/MacOS/mlx.metallib" \
    "$APP/Contents/embedded.provisionprofile" \
    "$resources/Chivo-Regular.ttf" \
    "$resources/Chivo-Medium.ttf" \
    "$resources/DarkbloomProvider_DarkbloomApp.bundle/default.metallib" \
    "$resources/mlx-swift-lm_MLXLMCommon.bundle/pagedattention.metal"
do
    [ -s "$resource" ] || fail "required payload is missing or empty: $resource"
done

for marker in \
    "$resources/darkbloom-runtime-capabilities/fan-helper-v1" \
    "$resources/darkbloom-runtime-capabilities/paged-kernel-v1"
do
    [ "$(wc -c < "$marker" | tr -d '[:space:]')" = "2" ] \
        && [ "$(tr -d '\n' < "$marker")" = "1" ] \
        || fail "capability marker must contain exactly 1 followed by newline: $marker"
done

paged_count=$(
    /usr/bin/find "$resources" \
        -type f -name pagedattention.metal -print \
        | /usr/bin/wc -l \
        | /usr/bin/tr -d '[:space:]'
)
[ "$paged_count" = "1" ] \
    || fail "exactly one pagedattention.metal is required (found $paged_count)"

echo "macOS release payload structure verified"
