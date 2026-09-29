#!/usr/bin/env python3
"""Evaluate a content-addressed raw receipt without installing or promoting it."""
import argparse
import json
from pathlib import Path

from serving_performance.evaluate import evaluate


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("receipt", type=Path, help="raw qualification JSON (schema_version=1)")
    parser.add_argument("--output", type=Path, help="write the derived review report here")
    args = parser.parse_args()
    try:
        report = evaluate(args.receipt.read_bytes())
    except (OSError, ValueError, TypeError, KeyError) as error:
        parser.error(str(error))
    encoded = json.dumps(report, indent=2, sort_keys=True, allow_nan=False) + "\n"
    if args.output:
        args.output.write_text(encoded)
    else:
        print(encoded, end="")
    return 0 if report["qualified"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
