#!/usr/bin/env python3
"""Join preserved supervised isolated runs; validation never selects phase rates."""
import argparse
import json
from pathlib import Path

from serving_performance.deadline_receipts import assemble_deadline_receipt
from serving_performance.deadline_evidence import reference_run, verified_source_runs


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("runs", nargs="+", type=Path)
    parser.add_argument("--profile-id", required=True)
    parser.add_argument("--prompt-min", type=int, required=True)
    parser.add_argument("--prompt-max", type=int, required=True)
    parser.add_argument("--checks", type=Path, required=True, help="reviewed lifecycle/correctness receipt references")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--evidence-root", type=Path,
                        help="archive containing all raw runs and prerequisites (default: output directory)")
    args = parser.parse_args()
    root = args.evidence_root or args.output.resolve().parent
    references = [reference_run(path, root) for path in args.runs]
    value = assemble_deadline_receipt(
        verified_source_runs({"source_runs": references}, root),
        profile_id=args.profile_id, prompt_min=args.prompt_min, prompt_max=args.prompt_max,
        checks=json.loads(args.checks.read_bytes()))
    value["source_runs"] = references
    args.output.write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + "\n")


if __name__ == "__main__":
    main()
