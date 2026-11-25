#!/usr/bin/env bash
#
# Run one `swift test` selection (a filter plus extra arguments) and fail if
# it executed zero tests or skipped one.
#
# THE TRIPWIRE IS THE POINT. `swift test` exits 0 even when the swift-testing
# pass executes NOTHING — that is how the four paged suites sat dark for a
# release while the job stayed green, and a dark suite is indistinguishable
# from a passing one by exit code alone. So the run is only a gate if something
# asserts a non-zero executed count.
#
# This script exists because that assertion used to be copy-pasted once per
# suite. Four copies of a tripwire is four chances to edit one and miss three,
# on the exact check whose failure mode is silence. Prompt Parity
# (verify-prompt-parity.sh) runs its suite through it too.
#
# The CALLER keeps one workflow step per suite so a slow or failing suite is
# still attributable straight from the job summary; only the body is shared.
#
# Usage: run-nested-suite.sh <filter> [extra swift test args...]
#
# NESTED_SUITE_REPORT=<prefix> keeps the run's Swift Testing report as
# <prefix>-swift-testing.xml and its stdout as <prefix>.log, for a caller that
# counts the run again (Prompt Parity, for the provider shard audit:
# scripts/provider-test-shards.py counts).
set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "usage: $0 <test-filter> [extra swift test args...]" >&2
    exit 2
fi

filter="$1"
shift

# The gate names the xUnit report, and reads XCTest's serial summary: with
# --parallel, SwiftPM prints neither that summary nor the same report.
for argument in "$@"; do
    case "$argument" in
        --parallel | --xunit-output | --xunit-output=*)
            echo "$0: the gate does not accept $argument" >&2
            exit 2
            ;;
    esac
done

# Swift filters can contain long alternatives and path separators. Keep the
# temporary names independent of the selector; pass the full filter below.
work="$(mktemp -d -t "nested-suite.XXXXXX")"
trap 'rm -rf "$work"' EXIT
xunit="$work/xunit.xml" stdout_log="$work/stdout.log"
if [[ -n "${NESTED_SUITE_REPORT:-}" ]]; then
    xunit="$NESTED_SUITE_REPORT.xml" stdout_log="$NESTED_SUITE_REPORT.log"
    # A run that writes no report must not be counted from an earlier one.
    rm -f "$xunit" "$NESTED_SUITE_REPORT-swift-testing.xml" "$stdout_log"
fi

# The counts never come from the merged console. SwiftPM writes its own
# warnings to stderr, at no fixed point in the run, and the test process's
# output to stdout through a block buffer; merged into one pipe, a warning
# lands wherever that buffer last flushed. In run 44909219943 one landed
# between `✔ Test run with 29` and ` tests in 3 suites passed`, and a grep of
# the merged log reported zero executed tests.
#
# So the gate reads Swift Testing's counts and skips from its xUnit report
# (`<name>-swift-testing.xml`; `<name>.xml` itself when XCTest is disabled),
# and XCTest's from SwiftPM's stdout alone: without --parallel, SwiftPM 6.4
# writes no XCTest xUnit report. stderr goes straight to the log, and `tee`
# keeps stdout there too. pipefail, so a non-zero `swift test` still fails.
swift test --skip-build --filter "$filter" "$@" --xunit-output "$xunit" | tee "$stdout_log"

python3 - "$filter" "$xunit" "$stdout_log" <<'PY'
import re
import sys
from pathlib import Path
from xml.etree import ElementTree

label, xunit, stdout_log = sys.argv[1:]
xunit = Path(xunit)


def fail(message):
    print(f"::error::{label} {message}")
    raise SystemExit(1)


reports = [xunit.with_name(f"{xunit.stem}-swift-testing{xunit.suffix}"), xunit]
report = next((path for path in reports if path.is_file()), None)
if report is None:
    fail("wrote no Swift Testing xUnit report — the run did not finish, so the gate cannot count it")
try:
    root = ElementTree.parse(report).getroot()
    declared_skips = sum(int(suite.get("skipped") or 0) for suite in root.iter("testsuite"))
except (ElementTree.ParseError, ValueError) as error:
    fail(f"wrote an unreadable Swift Testing xUnit report ({error}) — the gate cannot count it")
cases = list(root.iter("testcase"))
swift_testing_skipped = max(declared_skips, sum(case.find("skipped") is not None for case in cases))
swift_testing = len(cases) - sum(case.find("skipped") is not None for case in cases)

# XCTest's outermost suite reports last, and its count includes the skipped
# cases: `Executed 2 tests, with 1 test skipped and 0 failures`.
console = Path(stdout_log).read_text(errors="replace")
summaries = re.findall(r"Executed (\d+) tests?, with (?:(\d+) tests? skipped and )?\d+ failures?", console)
xctest_run, xctest_skipped = (int(summaries[-1][0]), int(summaries[-1][1] or 0)) if summaries else (0, 0)
xctest_skipped = max(xctest_skipped, len(re.findall(r"Test Case '-\[.+?\]' skipped \(", console)))
xctest = xctest_run - xctest_skipped

# A test that ends itself with `Test.cancel` is not a skip: the report lists
# it as run, as the console count always did. StageLoadRealSamplerTests
# cancels when the host's pageout scan gives it nothing to judge.
skipped = swift_testing_skipped + xctest_skipped
print(f"{label}: executed {swift_testing} Swift Testing tests ({report.name}) and {xctest} XCTest tests; "
      f"{skipped} skipped")
errors = []
if swift_testing + xctest == 0:
    errors.append("executed ZERO tests — the gate did not run")
# A suite whose every case self-skips (XCTSkip on a missing fixture, a
# .disabled/.enabled(if:) trait nobody meant to trip) asserts nothing — the
# same dark-gate failure mode, one layer up. Fail on ANY skip: these
# selections are hermetic by design (every test they select is meant to run),
# so a skip here means a precondition broke, not that skipping was intended.
if skipped:
    errors.append("skipped one or more tests — a skipped gate gates nothing. If the skip is a broken "
                  "precondition (missing metallib, missing fixture), fix the precondition; do not let the "
                  "lane stay green on a suite that did not run its assertions.")
for error in errors:
    print(f"::error::{label} {error}")
raise SystemExit(1 if errors else 0)
PY
