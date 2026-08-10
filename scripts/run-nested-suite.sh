#!/usr/bin/env bash
#
# Run ONE swift-testing suite inside libs/mlx-swift-lm and fail if it executed
# zero tests.
#
# THE TRIPWIRE IS THE POINT. `swift test` exits 0 even when the swift-testing
# pass executes NOTHING — that is how the four paged suites sat dark for a
# release while the job stayed green, and a dark suite is indistinguishable
# from a passing one by exit code alone. So the run is only a gate if something
# asserts a non-zero executed count.
#
# This script exists because that assertion used to be copy-pasted once per
# suite. Four copies of a tripwire is four chances to edit one and miss three,
# on the exact check whose failure mode is silence.
#
# The CALLER keeps one workflow step per suite so a slow or failing suite is
# still attributable straight from the job summary; only the body is shared.
#
# Usage: run-nested-suite.sh <filter> [extra swift test args...]
set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "usage: $0 <test-filter> [extra swift test args...]" >&2
    exit 2
fi

filter="$1"
shift

log="$(mktemp -t "nested-suite-${filter}.XXXXXX")"

# `tee` so the suite's own output still reaches the job log; pipefail so a
# non-zero `swift test` is not swallowed by the pipe.
swift test --skip-build --filter "$filter" "$@" 2>&1 | tee "$log"

if ! grep -qE 'Test run with [1-9][0-9]* test|Executed [1-9][0-9]* test' "$log"; then
    echo "::error::${filter} executed ZERO tests — the gate did not run"
    exit 1
fi

# The executed-count check above is satisfiable by a run that SKIPPED every
# test it "executed", and the two frameworks report skips in DIFFERENT shapes
# (both reproduced on the pinned Swift 6.1 toolchain):
#
#   XCTest aggregate (CBv2KVSharingParityTests, CBv2PrefixCacheHasherTests):
#     Executed 2 tests, with 1 test skipped and 0 failures (0 unexpected) ...
#
#   swift-testing per-test line (the four CBv2Paged* suites):
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
# A suite whose every case self-skips (XCTSkip on a missing fixture, a
# .disabled/.enabled(if:) trait nobody meant to trip) asserts nothing — the
# same dark-gate failure mode, one layer up. Fail on ANY skip: these nested
# suites are hermetic by design (tiny models, no weights, no env gates), so a
# skip here means a precondition broke, not that skipping was intended.
if grep -qE '^[^A-Za-z0-9]*(Test|Suite) .+ skipped[.:]|with [1-9][0-9]* tests? skipped|skipped [1-9][0-9]* test' "$log"; then
    echo "::error::${filter} skipped one or more tests — a skipped gate gates" \
         "nothing. If the skip is a broken precondition (missing metallib," \
         "missing fixture), fix the precondition; do not let the lane stay" \
         "green on a suite that did not run its assertions."
    exit 1
fi
