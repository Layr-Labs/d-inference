#!/usr/bin/env bash
set -euo pipefail

[ "$(uname)" = "Darwin" ] || {
    echo "macOS code identity tests require Darwin" >&2
    exit 77
}

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/darkbloom-code-identity-test.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
VERIFIER="$REPO_ROOT/scripts/verify-macos-code-identity.sh"
TARGET="$ROOT/signed-tool"
cp /usr/bin/true "$TARGET"
chmod 0755 "$TARGET"

/usr/bin/codesign --force --options runtime --sign - \
    --identifier io.darkbloom.fixture "$TARGET"
"$VERIFIER" "$TARGET" io.darkbloom.fixture

if "$VERIFIER" "$TARGET" io.darkbloom.wrong; then
    echo "wrong signing identifier unexpectedly passed" >&2
    exit 1
fi

if "$VERIFIER" "$TARGET" io.darkbloom.fixture WRONGTEAM; then
    echo "wrong signing team unexpectedly passed" >&2
    exit 1
fi

printf 'tampered\n' >> "$TARGET"
if "$VERIFIER" "$TARGET" io.darkbloom.fixture; then
    echo "tampered signature unexpectedly passed" >&2
    exit 1
fi

echo "macOS code identity failure tests passed"
