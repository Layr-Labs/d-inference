#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPOSITORY="$(/usr/bin/plutil -extract repository raw -o - "$PACKAGE_DIR/ThirdParty/lume.lock.json")"
COMMIT="$(/usr/bin/plutil -extract commit raw -o - "$PACKAGE_DIR/ThirdParty/lume.lock.json")"
SOURCE_PATH="$(/usr/bin/plutil -extract path raw -o - "$PACKAGE_DIR/ThirdParty/lume.lock.json")"
EXPECTED_VERSION="$(/usr/bin/plutil -extract version raw -o - "$PACKAGE_DIR/ThirdParty/lume.lock.json")"
CHECKOUT="${DARKBLOOM_LUME_CHECKOUT:-$PACKAGE_DIR/../.external/cua-lume-${COMMIT:0:12}}"
INSTALL_DIR="${1:-$PACKAGE_DIR/.tools/lume-${COMMIT:0:12}/bin}"

if [[ ! "$COMMIT" =~ ^[0-9a-f]{40}$ ]] || [[ "$SOURCE_PATH" != "libs/lume" ]]; then
    echo "invalid Lume source pin" >&2
    exit 1
fi

if [[ ! -d "$CHECKOUT/.git" ]]; then
    mkdir -p "$(dirname "$CHECKOUT")"
    git clone --filter=blob:none --no-checkout "$REPOSITORY" "$CHECKOUT"
fi

ACTUAL_REMOTE="$(git -C "$CHECKOUT" remote get-url origin)"
if [[ "$ACTUAL_REMOTE" != "$REPOSITORY" ]]; then
    echo "refusing checkout with unexpected origin: $ACTUAL_REMOTE" >&2
    exit 1
fi

git -C "$CHECKOUT" fetch --depth=1 origin "$COMMIT"
git -C "$CHECKOUT" sparse-checkout init --cone
git -C "$CHECKOUT" sparse-checkout set "$SOURCE_PATH"
git -C "$CHECKOUT" checkout --detach "$COMMIT"

ACTUAL_COMMIT="$(git -C "$CHECKOUT" rev-parse HEAD)"
if [[ "$ACTUAL_COMMIT" != "$COMMIT" ]]; then
    echo "Lume checkout mismatch: expected $COMMIT, got $ACTUAL_COMMIT" >&2
    exit 1
fi

LUME_TELEMETRY_ENABLED=false \
INSTALL_DIR="$INSTALL_DIR" \
"$CHECKOUT/$SOURCE_PATH/scripts/install-local.sh" \
    --release \
    --no-background-service

ACTUAL_VERSION="$("$INSTALL_DIR/lume" --version)"
if [[ "$ACTUAL_VERSION" != "$EXPECTED_VERSION" ]]; then
    echo "Lume version mismatch: expected $EXPECTED_VERSION, got $ACTUAL_VERSION" >&2
    exit 1
fi

BINARY_SHA256="$(/usr/bin/shasum -a 256 "$INSTALL_DIR/lume" | /usr/bin/awk '{print $1}')"
PROVENANCE_FILE="$INSTALL_DIR/lume.provenance.json"
PROVENANCE_TEMP="$PROVENANCE_FILE.$$.partial"
trap 'rm -f "$PROVENANCE_TEMP"' EXIT HUP INT TERM
printf '%s\n' \
    '{' \
    '  "schema_version": 1,' \
    "  \"repository\": \"$REPOSITORY\"," \
    "  \"commit\": \"$COMMIT\"," \
    "  \"source_path\": \"$SOURCE_PATH\"," \
    "  \"version\": \"$EXPECTED_VERSION\"," \
    "  \"binary_sha256\": \"$BINARY_SHA256\"" \
    '}' > "$PROVENANCE_TEMP"
chmod 0444 "$PROVENANCE_TEMP"
mv -f "$PROVENANCE_TEMP" "$PROVENANCE_FILE"
trap - EXIT HUP INT TERM

echo "lume_commit=$ACTUAL_COMMIT"
echo "lume_version=$ACTUAL_VERSION"
echo "lume_sha256=$BINARY_SHA256"
echo "lume_provenance=$PROVENANCE_FILE"
