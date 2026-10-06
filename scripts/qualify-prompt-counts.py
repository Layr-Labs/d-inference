#!/usr/bin/env python3
"""Review independent rendered prompt counts against canonical routing estimates."""
import argparse
import json
from pathlib import Path
from serving_performance.prompt_count_calibration import evaluate_prompt_counts


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("provider_receipt", type=Path)
    parser.add_argument("coordinator_projection", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    report = evaluate_prompt_counts(args.provider_receipt.read_bytes(), args.coordinator_projection.read_bytes())
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True, allow_nan=False) + "\n")
    return 0 if report["qualified"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
