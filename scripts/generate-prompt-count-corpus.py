#!/usr/bin/env python3
"""Write a temporary synthetic rendered-token corpus; never a passing profile."""
import argparse
import base64
import json
from pathlib import Path
from serving_performance.prompt_corpus import generate


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model-id", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--body-output", type=Path, help="same original JSON bytes as JSONL for the Go projector")
    parser.add_argument("--calibration-count", type=int, default=24)
    parser.add_argument("--validation-count", type=int, default=60)
    parser.add_argument("--seed", type=int, default=20260928, help="freeze before collecting either partition")
    args = parser.parse_args()
    if not 20 <= args.calibration_count <= 1000 or not 20 <= args.validation_count <= 1000:
        parser.error("each partition count must be 20...1000 per shape")
    corpus = generate(args.model_id, args.calibration_count, args.validation_count, args.seed)
    args.output.write_text(json.dumps(corpus, indent=2) + "\n")
    args.output.chmod(0o600)
    if args.body_output:
        args.body_output.write_bytes(b"\n".join(base64.b64decode(row["request"]) for row in corpus) + b"\n")
        args.body_output.chmod(0o600)
    print(json.dumps({"samples": len(corpus), "output": str(args.output), "qualified": False}))


if __name__ == "__main__":
    main()
