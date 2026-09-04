#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEAM_ID="${TEAM_ID:-${APPLE_TEAM_ID:-SLDQ2GJ6TL}}"
PAIRS=(scripts/entitlements.plist provider-swift/entitlements.plist)

# Apple Team IDs are 10 uppercase alphanumerics. The check also guarantees the value
# carries no XML metacharacters, so sed cannot produce a malformed plist.
[[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || {
    echo "invalid TEAM_ID '${TEAM_ID}': expected 10 uppercase alphanumerics" >&2
    exit 64
}

render() {  # render <template> <dest>
    local tmp="$2.tmp.$$"
    trap 'rm -f "$tmp"' EXIT
    sed "s/\${TEAM_ID}/$TEAM_ID/g" "$1" > "$tmp"
    chmod 0644 "$tmp"
    mv "$tmp" "$2"
    trap - EXIT
}

case "${1:-write}" in
    write)
        for dest in "${PAIRS[@]}"; do render "$ROOT/$dest.template" "$ROOT/$dest"; done
        ;;
    check)
        for dest in "${PAIRS[@]}"; do
            tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
            sed "s/\${TEAM_ID}/$TEAM_ID/g" "$ROOT/$dest.template" > "$tmp"
            if ! cmp -s "$tmp" "$ROOT/$dest"; then
                echo "$dest drifted from $dest.template; edit the template, then run scripts/generate-entitlements.sh" >&2
                diff -u "$ROOT/$dest" "$tmp" >&2 || true
                exit 1
            fi
            rm -f "$tmp"; trap - EXIT
        done
        ;;
    *)
        echo "usage: $0 [write|check]" >&2
        exit 64
        ;;
esac

echo "entitlements: TEAM_ID=$TEAM_ID"
