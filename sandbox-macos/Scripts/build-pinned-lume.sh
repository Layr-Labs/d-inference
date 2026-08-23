#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPOSITORY="$(/usr/bin/plutil -extract repository raw -o - "$PACKAGE_DIR/ThirdParty/lume.lock.json")"
COMMIT="$(/usr/bin/plutil -extract commit raw -o - "$PACKAGE_DIR/ThirdParty/lume.lock.json")"
EXPECTED_VERSION="$(/usr/bin/plutil -extract version raw -o - "$PACKAGE_DIR/ThirdParty/lume.lock.json")"
CHECKOUT="${DARKBLOOM_LUME_CHECKOUT:-$PACKAGE_DIR/../.external/cua-lume-${COMMIT:0:12}}"
INSTALL_DIR="${1:-$PACKAGE_DIR/.tools/lume-${COMMIT:0:12}/bin}"

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
git -C "$CHECKOUT" sparse-checkout set libs/lume
git -C "$CHECKOUT" checkout --detach "$COMMIT"

ACTUAL_COMMIT="$(git -C "$CHECKOUT" rev-parse HEAD)"
if [[ "$ACTUAL_COMMIT" != "$COMMIT" ]]; then
    echo "Lume checkout mismatch: expected $COMMIT, got $ACTUAL_COMMIT" >&2
    exit 1
fi

LUME_TELEMETRY_ENABLED=false \
INSTALL_DIR="$INSTALL_DIR" \
"$CHECKOUT/libs/lume/scripts/install-local.sh" \
    --release \
    --no-background-service

ACTUAL_VERSION="$("$INSTALL_DIR/lume" --version)"
if [[ "$ACTUAL_VERSION" != "$EXPECTED_VERSION" ]]; then
    echo "Lume version mismatch: expected $EXPECTED_VERSION, got $ACTUAL_VERSION" >&2
    exit 1
fi

echo "lume_commit=$ACTUAL_COMMIT"
echo "lume_version=$ACTUAL_VERSION"
/usr/bin/shasum -a 256 "$INSTALL_DIR/lume"
