#!/usr/bin/env python3
"""Entry point for the non-blocking OpenRouter PR threat review."""
import json
import os
import signal
from pathlib import Path
from threat_review.runner import run, summarize
from threat_review.client import ScanTimeout

def scan_timeout(signum, frame):
    raise ScanTimeout("Full PR scan exceeded its runtime budget")


if __name__ == "__main__":
    # Leave time to publish an incomplete result before the 60-minute job limit.
    signal.signal(signal.SIGALRM, scan_timeout)
    signal.alarm(50 * 60)
    try:
        event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
        result = run(event, Path.cwd(), os.environ)
    except Exception:
        result = "Review unavailable (non-blocking): setup or GitHub API failed; no complete review was produced."
    finally:
        signal.alarm(0)
    summarize(result, os.environ)
