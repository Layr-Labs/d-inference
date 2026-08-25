#!/usr/bin/env bash
set -euo pipefail

[ "$#" -eq 2 ] || [ "$#" -eq 3 ] || {
    echo "usage: $0 <signed-code> <expected-identifier> [expected-team-id]" >&2
    exit 64
}
TARGET=$1
EXPECTED_IDENTIFIER=$2
EXPECTED_TEAM=${3:-}

fail() {
    echo "macOS code identity verification failed: $*" >&2
    exit 1
}

[ "$(uname)" = "Darwin" ] || fail "codesign verification requires macOS"
[ -f "$TARGET" ] || [ -d "$TARGET" ] \
    || fail "signed payload is missing: $TARGET"
/usr/bin/codesign --verify --strict --verbose=2 "$TARGET" \
    || fail "strict signature verification failed: $TARGET"

DETAIL=$(/usr/bin/codesign -dvvv "$TARGET" 2>&1) \
    || fail "could not inspect code identity: $TARGET"
IDENTIFIER=$(printf '%s\n' "$DETAIL" \
    | /usr/bin/awk -F= '/^Identifier=/{print $2; exit}')
[ "$IDENTIFIER" = "$EXPECTED_IDENTIFIER" ] \
    || fail "identifier is ${IDENTIFIER:-absent}, want $EXPECTED_IDENTIFIER: $TARGET"

if [ -n "$EXPECTED_TEAM" ]; then
    TEAM=$(printf '%s\n' "$DETAIL" \
        | /usr/bin/awk -F= '/^TeamIdentifier=/{print $2; exit}')
    [ "$TEAM" = "$EXPECTED_TEAM" ] \
        || fail "team is ${TEAM:-absent}, want $EXPECTED_TEAM: $TARGET"
    REQUIREMENT="anchor apple generic and identifier \"$EXPECTED_IDENTIFIER\" and certificate leaf[subject.OU] = \"$EXPECTED_TEAM\""
    /usr/bin/codesign --verify --strict --verbose=2 \
        "-R=$REQUIREMENT" "$TARGET" \
        || fail "Developer ID requirement failed: $TARGET"
fi
