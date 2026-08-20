"""Benchmark constants and command-line parsing."""

from __future__ import annotations

import argparse
from pathlib import Path


# Schema of the *wrapper* report (distinct from the per-benchmark payload
# schemas the Swift binary stamps onto `raw.*`). Consumers dispatch on it, so
# any field rename or required addition bumps it.
#
#   2 — the arrival summary carries measured delivered-topology evidence
#       (offsets, arrival error, tolerance, discarded attempts).
#   3 — `configuration.maxBatch` REMOVED in favour of the enumerated
#       `configuration.batchSizes` ladder, and a required top-level
#       `kvBackend` block added (requested selection, resolved backends,
#       per-batch-size resolution, posture violations).
#   4 — `kvBackend.byPhase` added (required): the backend EVERY phase built,
#       not just the decode curve's. The scheduler-prefill and arrival
#       commands now take the selection too, so `kvBackend.resolved` is the
#       whole run's population rather than the sweep's.
#   5 — required effective config-projected Gemma settings, validated across
#       all three subprocesses and pinned for baseline comparisons.
#   6 — CBv2 prefill-stack default flip (solo stripe 2048 + prompt narrowing
#       + packed prefill, d-inference#646): raw scheduler-prefill schema is 3
#       and records `soloPrefillStripeTokens`. Pre-flip baselines measured
#       plain 512-token chunks under identical-looking empty environments,
#       so cross-flip deltas would misattribute the posture change as a code
#       delta; the exact-match schema pin refuses them.
SCHEMA_VERSION = 6


DEFAULT_MODEL = "mlx-community/gemma-4-26B-A4B-it-qat-4bit"
# The canonical posture this release is measured under. Both defaults are
# load-bearing:
#
#   contiguous — `auto` resolves contiguous as of v0.8.1, but naming the
#                backend keeps every phase's release posture explicit and
#                prevents a future default flip from changing the benchmark.
#   1,2,4,8    — the current production concurrency default is B=4 under the
#                contiguous `auto` posture, while B=8 remains a supported
#                stress point. The list is sparse on
#                purpose: a dense 1..8 ladder doubles wall time for cells no
#                gate reads.
DEFAULT_KV_BACKEND = "contiguous"
DEFAULT_BATCH_SIZES = [1, 2, 4, 8]
KV_BACKENDS = ("auto", "contiguous", "paged")
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
    parser.add_argument(
        "--config",
        default=None,
        help="provider TOML passed to every darkbloom benchmark subprocess",
    )
    parser.add_argument(
        "--comparison-axis",
        choices=("code", "gemma-optimizations"),
        default="code",
        help=(
            "dimension allowed to differ from --baseline: code requires equal "
            "Gemma settings; gemma-optimizations requires equal binaries and "
            "different effective Gemma settings"
        ),
    )
    parser.add_argument("--iterations", type=int, default=3)
    parser.add_argument(
        "--prefill-lengths", type=parse_positive_ints, default=[128, 512, 2048]
    )
    parser.add_argument(
        "--batch-sizes",
        type=parse_positive_ints,
        default=list(DEFAULT_BATCH_SIZES),
        help=(
            "comma-separated decode batch sizes "
            f"(default {','.join(map(str, DEFAULT_BATCH_SIZES))})"
        ),
    )
    parser.add_argument(
        "--kv-backend",
        choices=KV_BACKENDS,
        default=DEFAULT_KV_BACKEND,
        help=(
            "KV backend every benchmark phase is built with "
            f"(default {DEFAULT_KV_BACKEND}; 'auto' may silently resolve "
            "either backend, so it cannot pin a measurement)"
        ),
    )
    parser.add_argument("--decode-prompt-tokens", type=int, default=64)
    parser.add_argument("--decode-tokens", type=int, default=64)
    parser.add_argument("--arrival-prompt-tokens", type=int, default=512)
    parser.add_argument("--arrival-decode-tokens", type=int, default=64)
    parser.add_argument("--label", default="")
    parser.add_argument("--output-dir", default="tmp/benchmarks")
    # Comparison is OPT-IN against an explicit report. There is deliberately
    # no committed baseline: one would be valid only on the exact machine,
    # model snapshot and engine configuration that recorded it, and a
    # reference that has silently drifted still yields confident-looking
    # percentages. Point this at a report you just produced — e.g. the OFF
    # half of a same-binary feature bracket — so both sides share a binary,
    # a host and a thermal state.
    parser.add_argument(
        "--baseline",
        default=None,
        help="path to a previous report JSON to diff against (default: no comparison)",
    )
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--skip-metallib", action="store_true")
    args = parser.parse_args()

    numeric = {
        "--iterations": args.iterations,
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
    if len(set(args.batch_sizes)) != len(args.batch_sizes):
        parser.error("--batch-sizes must not contain duplicates")
    args.batch_sizes = sorted(args.batch_sizes)
    return args
