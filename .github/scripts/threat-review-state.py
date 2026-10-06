#!/usr/bin/env python3
"""Explicit ledger initialization using the maintainer's existing GH_TOKEN."""
import argparse
import os
import re
from threat_review.client import GitHub
from threat_review.state import initialize

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--base", required=True, help="full trusted base commit SHA")
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.repository):
        raise SystemExit("Invalid repository")
    try:
        initialize(GitHub(args.repository, 0, os.environ["GH_TOKEN"]), args.base)
    except Exception:
        raise SystemExit("Initialization failed or state already exists. No ledger was reset; inspect branch permissions.")
    print("Pilot ledger initialized. Paid scans remain disabled until explicitly enabled.")
