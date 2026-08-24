#!/bin/bash

set -euo pipefail

if [[ $# -ne 1 ]] || [[ "$1" != /* ]] || [[ ! -f "$1/Package.swift" ]]; then
    echo "usage: $0 /absolute/path/to/patched/lume/source" >&2
    exit 2
fi

SOURCE_ROOT="$1"
TEST_LOG="$(mktemp "${TMPDIR:-/tmp}/darkbloom-lume-tests.XXXXXX")"
cleanup() {
    rm -f "$TEST_LOG"
}
trap cleanup EXIT HUP INT TERM

(
    cd "$SOURCE_ROOT"
    swift test
) 2>&1 | tee "$TEST_LOG"

# SwiftPM exits successfully when discovery executes zero tests. Accept the
# aggregate emitted by either XCTest or swift-testing, but require a positive
# executed count so CI cannot silently stop exercising the pinned patch.
if ! /usr/bin/grep -qE \
    'Test run with [1-9][0-9]* test|Executed [1-9][0-9]* test' \
    "$TEST_LOG"; then
    echo "patched Lume test run executed zero tests" >&2
    exit 1
fi

echo "patched_lume_tests=nonzero"
