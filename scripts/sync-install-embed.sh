#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SOURCE="$ROOT/scripts/install.sh"
EMBEDDED="$ROOT/coordinator/api/install.sh"

require_canonical_worker_contract() {
    local needle count
    for needle in \
        'Contents/XPCServices/DarkbloomInferenceWorker.xpc' \
        'io.darkbloom.provider.inference-worker' \
        'certificate leaf[subject.OU] = "SLDQ2GJ6TL"' \
        'SLDQ2GJ6TL.io.darkbloom.provider.inference-worker' \
        'SLDQ2GJ6TL.io.darkbloom.provider' \
        'com.apple.security.app-sandbox' \
        'com.apple.security.files.bookmarks.app-scope' \
        'Contents/embedded.provisionprofile' \
        'security cms -D -i "$profile"' \
        'Entitlements:application-identifier' \
        'darkbloom-verify.XXXXXX' \
        'mlx-swift-lm_MLXLMCommon.bundle/pagedattention.metal' \
        'mktemp -d "${TMPDIR:-/tmp}/darkbloom-install.XXXXXX"' \
        '--sandbox-self-test-v1' \
        'DBXPC_SANDBOX_SELF_TEST_V1:63'
    do
        count=$(grep -F -c -- "$needle" "$SOURCE" || true)
        [ "$count" -ge 1 ] || {
            echo "canonical installer is missing worker-XPC contract: $needle" >&2
            return 1
        }
    done
}

require_canonical_worker_contract

case "${1:-write}" in
    write)
        tmp="${EMBEDDED}.tmp.$$"
        trap 'rm -f "$tmp"' EXIT
        cp "$SOURCE" "$tmp"
        chmod 0644 "$tmp"
        mv "$tmp" "$EMBEDDED"
        trap - EXIT
        ;;
    check)
        if ! cmp -s "$SOURCE" "$EMBEDDED"; then
            echo "embedded installer drifted; run scripts/sync-install-embed.sh" >&2
            diff -u "$SOURCE" "$EMBEDDED" >&2 || true
            exit 1
        fi
        ;;
    *)
        echo "usage: $0 [write|check]" >&2
        exit 64
        ;;
esac

echo "installer parity: scripts/install.sh == coordinator/api/install.sh"
