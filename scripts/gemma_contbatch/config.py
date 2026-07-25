"""Benchmark constants and command-line parsing."""

from __future__ import annotations

import argparse
from pathlib import Path


DEFAULT_MODEL = "mlx-community/gemma-4-26B-A4B-it-qat-4bit"
BASELINE_RELATIVE_PATH = Path(
    "docs/reports/2026-07-23-gemma-4-26b-qat4bit-continuous-batching-baseline.json"
)
EXPECTED_ARRIVAL_PATTERNS = {
    "burst": [0, 0, 0, 0],
    "stagger-25ms": [0, 25, 50, 75],
    "stagger-100ms": [0, 100, 200, 300],
    "rolling-250ms": [0, 250, 500, 750],
}


def parse_positive_ints(value: str) -> list[int]:
    try:
        values = [int(part.strip()) for part in value.split(",") if part.strip()]
    except ValueError as error:
        raise argparse.ArgumentTypeError("expected comma-separated integers") from error
    if not values or any(item <= 0 for item in values):
        raise argparse.ArgumentTypeError("values must be positive integers")
    return values


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Build Darkbloom and run Gemma raw-prefill, production-TTFT, "
            "decode-batch, and arrival-invariance benchmarks."
        )
    )
    parser.add_argument("--model", default=DEFAULT_MODEL)
    parser.add_argument("--iterations", type=int, default=3)
    parser.add_argument(
        "--prefill-lengths", type=parse_positive_ints, default=[128, 512, 2048]
    )
    parser.add_argument("--max-batch", type=int, default=4)
    parser.add_argument("--decode-prompt-tokens", type=int, default=64)
    parser.add_argument("--decode-tokens", type=int, default=64)
    parser.add_argument("--arrival-prompt-tokens", type=int, default=512)
    parser.add_argument("--arrival-decode-tokens", type=int, default=64)
    parser.add_argument("--label", default="")
    parser.add_argument("--output-dir", default="tmp/benchmarks")
    parser.add_argument("--baseline", default=str(BASELINE_RELATIVE_PATH))
    parser.add_argument("--no-compare", action="store_true")
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--skip-metallib", action="store_true")
    args = parser.parse_args()

    numeric = {
        "--iterations": args.iterations,
        "--max-batch": args.max_batch,
        "--decode-prompt-tokens": args.decode_prompt_tokens,
        "--decode-tokens": args.decode_tokens,
        "--arrival-prompt-tokens": args.arrival_prompt_tokens,
        "--arrival-decode-tokens": args.arrival_decode_tokens,
    }
    invalid = [name for name, value in numeric.items() if value <= 0]
    if invalid:
        parser.error(f"{', '.join(invalid)} must be positive")
    if any(length < 2 for length in args.prefill_lengths):
        parser.error("--prefill-lengths values must be >= 2")
    if len(set(args.prefill_lengths)) != len(args.prefill_lengths):
        parser.error("--prefill-lengths must not contain duplicates")
    return args
