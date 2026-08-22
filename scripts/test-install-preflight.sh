#!/bin/bash
# Platform-independent installer preflight tests.
#
# scripts/test-install-atomic.sh needs codesign, clang, and BSD stat, so it can
# only run on the macOS CI job. The macOS floor gate is the one piece of
# installer logic that must be right on machines Darkbloom refuses to install
# on, so it is exercised here where every PR runs it.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
"$REPO_ROOT/scripts/sync-install-embed.sh" check >/dev/null

failures=0

expect_gate() {
    local installer=$1
    local have=$2
    local want=$3
    local expected=$4
    local actual

    if bash "$installer" --version-gate-test "$have" "$want"; then
        actual=allow
    else
        actual=block
    fi
    if [ "$actual" != "$expected" ]; then
        echo "✗ $(basename "$(dirname "$installer")")/install.sh:" \
            "$have vs $want -> $actual (expected $expected)" >&2
        failures=$((failures + 1))
    fi
}

for installer in \
    "$REPO_ROOT/scripts/install.sh" \
    "$REPO_ROOT/coordinator/api/install.sh"
do
    min_macos=$(bash "$installer" --min-macos-test)
    [ -n "$min_macos" ] || {
        echo "✗ $installer does not report MIN_MACOS" >&2
        exit 1
    }

    # The exact host from the v0.8.9 install failure, and its neighbours.
    expect_gate "$installer" "15.7.9" "$min_macos" allow
    expect_gate "$installer" "15.0" "$min_macos" allow
    expect_gate "$installer" "14.7.6" "$min_macos" block
    expect_gate "$installer" "26.2" "$min_macos" allow

    # Component-wise numeric compare, not lexicographic: 15.10 > 15.9, and a
    # zero-padded or truncated version string must not flip the verdict.
    expect_gate "$installer" "15.10" "15.9" allow
    expect_gate "$installer" "15.9" "15.10" block
    expect_gate "$installer" "26" "26.2" block
    expect_gate "$installer" "26.02" "26.2" allow
    expect_gate "$installer" "15" "15.0" allow
    expect_gate "$installer" "15.0.0" "15.0" allow

    # Beta/build suffixes must not be read as a lower version.
    expect_gate "$installer" "26.2-beta" "26.2" allow
done

if [ "$failures" -ne 0 ]; then
    echo "installer preflight tests failed ($failures)" >&2
    exit 1
fi
echo "installer preflight tests passed"
