#!/usr/bin/env python3
"""Evaluate exact, narrowly scoped deadline evidence; never alter serving defaults."""
import argparse
import json
from pathlib import Path

from serving_performance.deadline_profile import evaluate_deadline_profile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("receipt", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    result = evaluate_deadline_profile(args.receipt.read_bytes())
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True, allow_nan=False) + "\n")
    return 0 if result["qualified"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
