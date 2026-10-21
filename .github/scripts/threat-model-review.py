#!/usr/bin/env python3
"""Trusted PR review; the separate gate evaluates optional merge clearance."""
import json
import os
import signal
from pathlib import Path
from threat_review.runner import summarize
from threat_review.budget_runner import run
from threat_review.client import ScanTimeout
from threat_review.diagnostics import failure_record, write_diagnostics

def scan_timeout(signum, frame):
    raise ScanTimeout("Full PR scan exceeded its runtime budget")


if __name__ == "__main__":
    # Leave time to publish saved partial feedback before the workflow deadline.
    signal.signal(signal.SIGALRM, scan_timeout)
    signal.alarm(15 * 60)
    try:
        event = json.loads(Path(os.environ.get("THREAT_REVIEW_EVENT_PATH", os.environ["GITHUB_EVENT_PATH"])).read_text())
        result = run(event, Path.cwd(), os.environ)
    except Exception as error:
        write_diagnostics(os.environ, {"diagnostics": [failure_record(error, {"stage": "setup"})]})
        result = "Review unavailable: setup or GitHub API failed; no complete review was produced."
    finally:
        signal.alarm(0)
    summarize(result, os.environ)
