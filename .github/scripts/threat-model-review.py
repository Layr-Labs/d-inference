#!/usr/bin/env python3
"""Trusted PR review; the separate gate evaluates optional merge clearance."""
import json
import os
import signal
from pathlib import Path
from threat_review.runner import summarize
from threat_review.budget_runner import ResultWriteFailure, run
from threat_review.client import ReviewUnavailable, ScanTimeout
from threat_review.diagnostics import failure_record, write_diagnostics

def scan_timeout(signum, frame):
    raise ScanTimeout("Full PR scan exceeded its runtime budget")


def runtime_seconds(env):
    try:
        seconds = int(env.get("THREAT_REVIEW_TIMEOUT_SECONDS") or 900)
    except (TypeError, ValueError):
        raise ReviewUnavailable("Invalid THREAT_REVIEW_TIMEOUT_SECONDS") from None
    if not 60 <= seconds <= 3000:
        raise ReviewUnavailable("Invalid THREAT_REVIEW_TIMEOUT_SECONDS")
    return seconds


if __name__ == "__main__":
    # Leave time to publish saved partial feedback before the workflow deadline.
    signal.signal(signal.SIGALRM, scan_timeout)
    exit_code = 0
    try:
        signal.alarm(runtime_seconds(os.environ))
        event = json.loads(Path(os.environ.get("THREAT_REVIEW_EVENT_PATH", os.environ["GITHUB_EVENT_PATH"])).read_text())
        result = run(event, os.environ)
    except ResultWriteFailure as error:
        write_diagnostics(os.environ, error.snapshot)
        result = error.summary
        exit_code = 1
    except Exception as error:
        write_diagnostics(os.environ, {"diagnostics": [failure_record(error, {"stage": "setup"})]})
        result = ("Human review required: setup or GitHub API failed; no complete review was produced. "
                  "Do not manually rerun the paid scan.")
    finally:
        signal.alarm(0)
    summarize(result, os.environ)
    raise SystemExit(exit_code)
