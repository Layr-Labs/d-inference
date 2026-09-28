#!/usr/bin/env python3
"""Entry point for the non-blocking OpenRouter PR threat review."""
import json
import os
from pathlib import Path
from threat_review.runner import run, summarize

if __name__ == "__main__":
    try:
        event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
        result = run(event, Path.cwd(), os.environ)
    except Exception:
        result = "Review unavailable (non-blocking): setup or GitHub API failed; no complete review was produced."
    summarize(result, os.environ)
