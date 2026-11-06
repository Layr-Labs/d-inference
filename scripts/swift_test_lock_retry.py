#!/usr/bin/env python3
"""Whether a failed `swift test` run failed only on SwiftPM's locked build database.

Processes that share one build (`swift test --skip-build --ignore-lock`) can
start together. SwiftPM in one of them can then find the build database
locked by another's startup; it prints one of

    error: unable to attach DB: error: accessing build database "...": database is locked ...
    error: error: accessing build database "...": database is locked ...

(the second in run 42057277814), runs the tests anyway, and exits 1. Such a run may run once more, but only
when its log proves that every test it ran passed, so the exit status can
have no other cause:

- the lock message is there;
- Swift Testing's summary says the run passed, and no line reports a failed
  test, a failed run or an issue (`✘`);
- every XCTest summary has 0 failures, and no XCTest case failed;
- no `::error::` line (run-nested-suite.sh's tripwires) is there.

Usage: swift_test_lock_retry.py LOG
Exit status 0: only the lock failed, run once more. 1: do not run again.
"""

from pathlib import Path
import re
import sys

LOCKED = re.compile(r"(?:unable to attach DB|accessing build database)\b.*database is locked")
SWIFT_TESTING_PASSED = re.compile(r"Test run with \d+ tests?(?: in \d+ suites?)? passed after")
FAILED = re.compile(r"✘|Test run with .* failed|Test Case .* failed|^::error::", re.MULTILINE)
XCTEST_SUMMARY = re.compile(r"Executed \d+ tests?, with (?:\d+ tests? skipped and )?(\d+) failures? \((\d+) unexpected\)")


def only_locked(text):
    """True when the log shows the lock message and nothing else that fails."""
    if not LOCKED.search(text) or not SWIFT_TESTING_PASSED.search(text) or FAILED.search(text):
        return False
    return all(failures == "0" and unexpected == "0" for failures, unexpected in XCTEST_SUMMARY.findall(text))


def main(argv):
    if len(argv) != 2:
        print(__doc__.split("\n\n", 1)[0], file=sys.stderr)
        return 2
    return 0 if only_locked(Path(argv[1]).read_text(errors="replace")) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
