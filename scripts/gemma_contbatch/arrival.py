"""Strict validation of the arrival-invariance payload.

Two independent things have to hold before an arrival number means anything:
the measured matrix must be complete and bit-exact across topologies (here),
and the topology the engine received must be the one the pattern is named for
(`arrival_timing`). Both are fail-closed.
"""

from __future__ import annotations

import argparse
from collections import defaultdict
from statistics import median

from .arrival_timing import validate_arrival_bounds, validate_pattern_arrival
from .checks import close_enough, require_positive
from .config import EXPECTED_ARRIVAL_PATTERNS


def validate_pattern_rows(
    name: str, sample: dict, delays: list[int], decode_tokens: int
) -> list[dict]:
    rows = sample.get("rows", [])
    if len(rows) != len(delays) or {row.get("row") for row in rows} != set(
        range(len(delays))
    ):
        raise RuntimeError(
            f"arrival topology {name} iteration {sample.get('iteration')} "
            "has incomplete rows"
        )
    for row in rows:
        if row.get("generatedTokens") != decode_tokens:
            raise RuntimeError(
                f"arrival topology {name} row {row.get('row')} completed "
                f"{row.get('generatedTokens')} tokens"
            )
        for key in ("ttftMs", "decodeTokensPerSecond", "completedAtMs"):
            require_positive(
                row.get(key), f"arrival.{name}.row[{row.get('row')}].{key}"
            )
        if not row.get("tokenChecksum"):
            raise RuntimeError(
                f"arrival topology {name} row {row.get('row')} has no checksum"
            )
    return rows


def validate_pattern_medians(name: str, pattern: dict, samples: list[dict]) -> None:
    all_rows = [row for sample in samples for row in sample["rows"]]
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
        if not close_enough(pattern[key], computed):
            raise RuntimeError(
                f"arrival topology {name} reported inconsistent {key}: "
                f"{pattern[key]} vs recomputed {computed}"
            )


def validate_checksums(checksum_sets: dict[str, dict[int, set[str]]]) -> None:
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


def validate_arrival(args: argparse.Namespace, arrival: dict) -> None:
    if arrival.get("promptTokensPerRequest") != args.arrival_prompt_tokens:
        raise RuntimeError("arrival benchmark reported the wrong prompt length")
    if arrival.get("decodeTokensPerRequest") != args.arrival_decode_tokens:
        raise RuntimeError("arrival benchmark reported the wrong decode budget")
    tolerance, max_attempts = validate_arrival_bounds(arrival)

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
            for row in validate_pattern_rows(
                name, sample, delays, args.arrival_decode_tokens
            ):
                checksum_sets[name][int(row["row"])].add(row["tokenChecksum"])

        validate_pattern_medians(name, pattern, samples)
        # Only now, with a complete and self-consistent matrix, is it worth
        # asking whether the arrivals that produced it were the named topology.
        validate_pattern_arrival(name, pattern, delays, tolerance, max_attempts)

    validate_checksums(checksum_sets)
