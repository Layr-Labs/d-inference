"""Strict validation of raw benchmark output."""

from __future__ import annotations

import argparse
from collections import Counter

from .arrival import validate_arrival
from .checks import assert_finite, require_positive


def validate_prefill(args: argparse.Namespace, sweep: dict) -> None:
    expected_prefill_counts = Counter(
        {length: args.iterations for length in args.prefill_lengths}
    )
    prefill_samples = sweep.get("prefill", [])
    actual_prefill_counts = Counter(
        int(sample.get("promptTokens", -1)) for sample in prefill_samples
    )
    if actual_prefill_counts != expected_prefill_counts:
        raise RuntimeError(
            "raw prefill matrix incomplete: "
            f"expected {expected_prefill_counts}, got {actual_prefill_counts}"
        )
    for index, sample in enumerate(prefill_samples):
        require_positive(sample.get("elapsedMs"), f"prefill[{index}].elapsedMs")
        require_positive(
            sample.get("prefillTokensPerSecond"),
            f"prefill[{index}].prefillTokensPerSecond",
        )


def validate_decode(args: argparse.Namespace, sweep: dict) -> None:
    # The decode curve is repeated once per iteration, so every requested batch
    # size must carry exactly `--iterations` samples; anything else means the
    # median in the summary would be computed over the wrong number of
    # measurements. The expectation is the `--batch-sizes` list verbatim: a
    # sparse curve must not be silently accepted as a dense ladder, nor the
    # reverse.
    decode_samples = sweep.get("decode", [])
    expected_decode_counts = Counter(
        {batch_size: args.iterations for batch_size in args.batch_sizes}
    )
    actual_decode_counts = Counter(
        int(sample.get("batchSize", -1)) for sample in decode_samples
    )
    if actual_decode_counts != expected_decode_counts:
        raise RuntimeError(
            "decode matrix incomplete: "
            f"expected {expected_decode_counts}, got {actual_decode_counts}"
        )
    for index, sample in enumerate(decode_samples):
        batch_size = int(sample["batchSize"])
        if sample.get("decodeTokensPerSequence") != args.decode_tokens:
            raise RuntimeError(f"decode[{index}] reported the wrong token budget")
        for key in (
            "elapsedMs",
            "aggregateTokensPerSecond",
            "perSequenceTokensPerSecond",
        ):
            require_positive(sample.get(key), f"decode[{index}].{key}")
        observed_tokens = (
            sample["aggregateTokensPerSecond"] * sample["elapsedMs"] / 1000.0
        )
        expected_tokens = batch_size * args.decode_tokens
        if abs(observed_tokens - expected_tokens) > 0.5:
            raise RuntimeError(
                f"decode[{index}] completed {observed_tokens:.2f} tokens, "
                f"expected {expected_tokens}"
            )


def validate_scheduler(args: argparse.Namespace, scheduler: dict) -> None:
    scheduler_samples = scheduler.get("samples", [])
    expected_scheduler_keys = {
        (length, iteration)
        for length in args.prefill_lengths
        for iteration in range(1, args.iterations + 1)
    }
    actual_scheduler_keys = {
        (int(sample.get("promptTokens", -1)), int(sample.get("iteration", -1)))
        for sample in scheduler_samples
    }
    if (
        len(scheduler_samples) != len(expected_scheduler_keys)
        or actual_scheduler_keys != expected_scheduler_keys
    ):
        raise RuntimeError("scheduler TTFT matrix is incomplete")
    for index, sample in enumerate(scheduler_samples):
        require_positive(sample.get("ttftMs"), f"scheduler[{index}].ttftMs")
        require_positive(
            sample.get("msPerPrefillToken"),
            f"scheduler[{index}].msPerPrefillToken",
        )


def validate_raw_outputs(
    args: argparse.Namespace, sweep: dict, scheduler: dict, arrival: dict
) -> None:
    for name, payload in (
        ("throughput sweep", sweep),
        ("scheduler prefill", scheduler),
        ("arrival invariance", arrival),
    ):
        if payload.get("modelID", "").replace("\\/", "/") != args.model:
            raise RuntimeError(f"{name} returned the wrong model ID")
        assert_finite(payload, name)

    validate_prefill(args, sweep)
    validate_decode(args, sweep)
    validate_scheduler(args, scheduler)
    validate_arrival(args, arrival)
