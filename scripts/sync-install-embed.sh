#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SOURCE="$ROOT/scripts/install.sh"
EMBEDDED="$ROOT/coordinator/api/install.sh"

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
