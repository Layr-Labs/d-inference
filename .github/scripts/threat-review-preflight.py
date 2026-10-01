#!/usr/bin/env python3
"""Verify the configured writer and funding without issuing paid model calls."""
import os
from threat_review.client import GitHub, ReviewUnavailable
from threat_review.preflight import check
from threat_review.state import State

if __name__ == "__main__":
    state = State(GitHub(os.environ["GITHUB_REPOSITORY"], 0, os.environ["GH_TOKEN"]))
    try:
        check(state, os.environ["OPENROUTER_API_KEY"])
    except Exception as error:
        # Fixed error text only; provider payloads and credentials stay private.
        print(str(error) if isinstance(error, ReviewUnavailable) else "Preflight unavailable")
        raise SystemExit(1) from None
    print("State read/write and commit signature verified; provider funding available. No paid calls made.")
