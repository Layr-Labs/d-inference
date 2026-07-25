"""Strict validation of raw benchmark output."""

from __future__ import annotations

import argparse
import math
from collections import Counter, defaultdict
from statistics import median

from .config import EXPECTED_ARRIVAL_PATTERNS


def assert_finite(value: object, path: str = "root") -> None:
    if isinstance(value, float) and not math.isfinite(value):
        raise RuntimeError(f"non-finite metric at {path}: {value}")
    if isinstance(value, dict):
        for key, child in value.items():
            assert_finite(child, f"{path}.{key}")
    elif isinstance(value, list):
        for index, child in enumerate(value):
            assert_finite(child, f"{path}[{index}]")


def require_positive(value: object, path: str) -> None:
    if not isinstance(value, (int, float)) or isinstance(value, bool) or value <= 0:
        raise RuntimeError(f"expected positive metric at {path}, got {value!r}")


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

    decode_samples = sweep.get("decode", [])
    expected_batches = set(range(1, args.max_batch + 1))
    actual_batches = {int(sample.get("batchSize", -1)) for sample in decode_samples}
    if len(decode_samples) != args.max_batch or actual_batches != expected_batches:
        raise RuntimeError(
            f"decode matrix incomplete: expected {expected_batches}, got {actual_batches}"
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

    if arrival.get("promptTokensPerRequest") != args.arrival_prompt_tokens:
        raise RuntimeError("arrival benchmark reported the wrong prompt length")
    if arrival.get("decodeTokensPerRequest") != args.arrival_decode_tokens:
        raise RuntimeError("arrival benchmark reported the wrong decode budget")
    patterns = arrival.get("patterns", [])
    pattern_by_name = {pattern.get("name"): pattern for pattern in patterns}
    if len(patterns) != len(EXPECTED_ARRIVAL_PATTERNS) or set(pattern_by_name) != set(
        EXPECTED_ARRIVAL_PATTERNS
    ):
        raise RuntimeError("arrival topology matrix is incomplete")
    checksum_sets: dict[str, dict[int, set[str]]] = {}
    for name, delays in EXPECTED_ARRIVAL_PATTERNS.items():
        pattern = pattern_by_name[name]
        if pattern.get("arrivalDelaysMs") != delays:
            raise RuntimeError(f"arrival topology {name} has unexpected delays")
        if not pattern.get("outputsStableAcrossIterations") or not pattern.get(
            "outputsMatchBurst"
        ):
            raise RuntimeError(f"arrival topology {name} failed exact output invariance")
        samples = pattern.get("samples", [])
        actual_iterations = {sample.get("iteration") for sample in samples}
        expected_iterations = set(range(1, args.iterations + 1))
        if len(samples) != args.iterations or actual_iterations != expected_iterations:
            raise RuntimeError(f"arrival topology {name} has incomplete iterations")
        all_rows: list[dict] = []
        checksum_sets[name] = defaultdict(set)
        for sample_index, sample in enumerate(samples):
            for key in (
                "aggregateDecodeTokensPerSecond",
                "endToEndTokensPerSecond",
                "makespanMs",
            ):
                require_positive(
                    sample.get(key), f"arrival.{name}[{sample_index}].{key}"
                )
            rows = sample.get("rows", [])
            if len(rows) != len(delays) or {row.get("row") for row in rows} != set(
                range(len(delays))
            ):
                raise RuntimeError(
                    f"arrival topology {name} iteration {sample.get('iteration')} "
                    "has incomplete rows"
                )
            for row in rows:
                all_rows.append(row)
                if row.get("generatedTokens") != args.arrival_decode_tokens:
                    raise RuntimeError(
                        f"arrival topology {name} row {row.get('row')} completed "
                        f"{row.get('generatedTokens')} tokens"
                    )
                for key in (
                    "ttftMs",
                    "decodeTokensPerSecond",
                    "completedAtMs",
                ):
                    require_positive(
                        row.get(key),
                        f"arrival.{name}.row[{row.get('row')}].{key}",
                    )
                if not row.get("tokenChecksum"):
                    raise RuntimeError(
                        f"arrival topology {name} row {row.get('row')} has no checksum"
                    )
                checksum_sets[name][int(row["row"])].add(row["tokenChecksum"])

        computed_medians = {
            "medianTTFTMs": median(row["ttftMs"] for row in all_rows),
            "medianPerRequestDecodeTokensPerSecond": median(
                row["decodeTokensPerSecond"] for row in all_rows
            ),
            "medianAggregateDecodeTokensPerSecond": median(
                sample["aggregateDecodeTokensPerSecond"] for sample in samples
            ),
            "medianMakespanMs": median(sample["makespanMs"] for sample in samples),
        }
        for key, computed in computed_medians.items():
            require_positive(pattern.get(key), f"arrival.{name}.{key}")
            if not math.isclose(pattern[key], computed, rel_tol=1e-9, abs_tol=1e-6):
                raise RuntimeError(
                    f"arrival topology {name} reported inconsistent {key}: "
                    f"{pattern[key]} vs recomputed {computed}"
                )

    canonical_checksums: dict[int, str] = {}
    for row, checksums in checksum_sets["burst"].items():
        if len(checksums) != 1:
            raise RuntimeError(f"burst row {row} changed output across iterations")
        canonical_checksums[row] = next(iter(checksums))
    for name, rows in checksum_sets.items():
        for row, checksums in rows.items():
            if len(checksums) != 1:
                raise RuntimeError(
                    f"arrival topology {name} row {row} changed output across iterations"
                )
            if next(iter(checksums)) != canonical_checksums.get(row):
                raise RuntimeError(
                    f"arrival topology {name} row {row} differs from burst output"
                )
