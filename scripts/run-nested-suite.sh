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
