#!/usr/bin/env bash
#
# Run ONE filtered Swift test suite in the current package and fail if it
# executes zero tests or skips any test.
#
# THE TRIPWIRE IS THE POINT. `swift test` exits 0 even when the swift-testing
# pass executes NOTHING — that is how filtered paged suites sat dark for a
# release while the job stayed green, and a dark suite is indistinguishable
# from a passing one by exit code alone. So the run is only a gate if something
# asserts a non-zero executed count.
#
# Keep that assertion in one canonical wrapper for every explicit Swift lane.
# Copying the tripwire into workflows or Make targets creates more chances to
# update one check and miss another, on the exact failure mode that is silent.
#
# The CALLER keeps one workflow step per suite so a slow or failing suite is
# still attributable straight from the job summary; only the body is shared.
#
# Usage: run-swift-suite.sh <filter> [swift test args...]
set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "usage: $0 <test-filter> [extra swift test args...]" >&2
    exit 2
fi

filter="$1"
shift

log="$(mktemp -t "swift-suite.XXXXXX")"
trap 'rm -f "$log"' EXIT

# `tee` so the suite's own output still reaches the job log; pipefail so a
# non-zero `swift test` is not swallowed by the pipe.
swift test "$@" --filter "$filter" 2>&1 | tee "$log"

if ! grep -qE 'Test run with [1-9][0-9]* test|Executed [1-9][0-9]* test' "$log"; then
    echo "::error::${filter} executed ZERO tests — the gate did not run"
    exit 1
fi

# The executed-count check above is satisfiable by a run that SKIPPED every
# test it "executed", and the two frameworks report skips in DIFFERENT shapes
# (both reproduced on the pinned Swift 6.1 toolchain):
#
#   XCTest aggregate (for example CBv2KVSharingParityTests):
#     Executed 2 tests, with 1 test skipped and 0 failures (0 unexpected) ...
#
#   swift-testing per-test line (for example CBv2Paged* suites):
#     ✘ Test skip() skipped: "missing fixture"        (Swift 6.1 runtime)
#     ➜ Test skip() skipped: "missing fixture"        (Swift 6.3 runtime)
#     ✘ Test conditionSkip() skipped.                  (no-reason variant)
#   ...while its AGGREGATE counts skipped cases as passed —
#     ✔ Test run with 4 tests passed after 0.001 seconds.
#   — so there is no skip count to grep for; only the per-test line exists.
#
# The LEADING GLYPH IS TOOLCHAIN-DEPENDENT (✘ on 6.1, ➜ on 6.3; both
# reproduced empirically, and stable across tty/pipe, NO_COLOR, and
# SWT_SF_SYMBOLS_ENABLED) — so the pattern must not hardcode any glyph.
# `^[^A-Za-z0-9]*` anchors to line start and admits only glyph/space bytes
# before "Test"/"Suite", which keeps prose inside a test's own log output
# from matching while accepting whatever symbol a future runtime picks.
#
# A suite whose every case self-skips asserts nothing — the same dark-gate
# failure mode, one layer up. Fail on ANY skip: explicit filtered lanes are
# expected to have their declared prerequisites, so a skip means the lane is
# not exercising its promised contract.
if grep -qE '^[^A-Za-z0-9]*(Test|Suite) .+ skipped[.:]|with [1-9][0-9]* tests? skipped|skipped [1-9][0-9]* test' "$log"; then
    echo "::error::${filter} skipped one or more tests — a skipped gate gates" \
         "nothing. Satisfy the lane's runtime prerequisites or fixtures; do" \
         "not let the lane stay green when it did not run every assertion."
    exit 1
fi
