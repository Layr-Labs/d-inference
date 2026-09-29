#!/usr/bin/env python3
"""Join preserved supervised isolated runs; validation never selects phase rates."""
import argparse
import json
from pathlib import Path

from serving_performance.deadline_receipts import assemble_deadline_receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("runs", nargs="+", type=Path)
    parser.add_argument("--profile-id", required=True)
    parser.add_argument("--prompt-min", type=int, required=True)
    parser.add_argument("--prompt-max", type=int, required=True)
    parser.add_argument("--checks", type=Path, required=True, help="reviewed lifecycle/correctness receipt references")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    value = assemble_deadline_receipt(
        [((path / "receipt.json").read_bytes(), (path / "provenance.json").read_bytes()) for path in args.runs],
        profile_id=args.profile_id, prompt_min=args.prompt_min, prompt_max=args.prompt_max,
        checks=json.loads(args.checks.read_bytes()))
    args.output.write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + "\n")


if __name__ == "__main__":
    main()
