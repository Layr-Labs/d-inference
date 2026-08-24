#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_LOG="$(mktemp "${TMPDIR:-/tmp}/darkbloom-lume-publication-tests.XXXXXX")"

cleanup() {
    status=$?
    trap - EXIT HUP INT TERM
    /bin/rm -f -- "$TEST_LOG"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

/bin/bash "$SCRIPT_DIR/test-lume-runtime-publication.sh" 2>&1 \
    | tee "$TEST_LOG"

if ! /usr/bin/grep -qE '^lume_publication_contract_tests=[1-9][0-9]*$' \
    "$TEST_LOG"; then
    echo "Lume publication contract executed zero tests" >&2
    exit 1
fi

echo "lume_publication_contract_tripwire=nonzero"
