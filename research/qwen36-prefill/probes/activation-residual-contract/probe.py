#!/usr/bin/env python3
"""Numerical roof probe for cohort activation contraction.

This is deliberately an offline viability probe, not a throughput benchmark.
It applies an unchanged dense weight to a randomized activation basis, repairs
rows selected only from exact sentinel columns, and reports both numerical
error and fully charged MAC-equivalent accounting.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import time
from pathlib import Path
from typing import Any

import numpy as np

from budget import (
    b4_8k_composition,
    dense_budget,
    preregistered_b4_schedule,
)


SCREEN_THRESHOLDS = {
    "maximum_candidate_mac_fraction": 0.30,
    "maximum_output_nrmse": 0.01,
    "maximum_p99_row_relative_l2": 0.05,
    "minimum_p01_row_cosine": 0.995,
    "minimum_sentinel_worst_row_recall": 0.90,
}


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(16 * 1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def load_matrix(path: Path, name: str) -> np.ndarray:
    value = np.load(path, mmap_mode="r", allow_pickle=False)
    if not isinstance(value, np.ndarray) or value.ndim != 2:
        raise ValueError(f"{name} must be one rank-2 .npy array")
    if not np.issubdtype(value.dtype, np.floating):
        raise ValueError(f"{name} must have a floating dtype")
    if not np.isfinite(value).all():
        raise ValueError(f"{name} contains NaN or Inf")
    return value


def synthetic_matrices(
    *,
    rows: int,
    input_width: int,
    output_width: int,
    intrinsic_rank: int,
    noise: float,
    seed: int,
) -> tuple[np.ndarray, np.ndarray]:
    if intrinsic_rank <= 0 or intrinsic_rank > min(rows, input_width):
        raise ValueError("synthetic intrinsic rank is outside the matrix dimensions")
    if noise < 0:
        raise ValueError("synthetic noise cannot be negative")
    rng = np.random.default_rng(seed)
    left = rng.standard_normal((rows, intrinsic_rank), dtype=np.float32)
    right = rng.standard_normal((intrinsic_rank, input_width), dtype=np.float32)
    activations = (left @ right) / math.sqrt(intrinsic_rank)
    if noise:
        activations += noise * rng.standard_normal(
            activations.shape, dtype=np.float32
        )
    weights = rng.standard_normal(
        (input_width, output_width), dtype=np.float32
    ) / math.sqrt(input_width)
    return activations, weights


def orthonormal_activation_basis(
    activations: np.ndarray,
    *,
    rank: int,
    power_iterations: int,
    seed: int,
) -> tuple[np.ndarray, np.ndarray]:
    rows, input_width = activations.shape
    if rank <= 0 or rank > min(rows, input_width):
        raise ValueError("rank is outside the activation matrix dimensions")
    if power_iterations < 0:
        raise ValueError("power iterations cannot be negative")

    rng = np.random.default_rng(seed)
    omega = rng.standard_normal((input_width, rank), dtype=np.float32)
    sample = np.asarray(activations @ omega, dtype=np.float32)
    basis_rows, _ = np.linalg.qr(sample, mode="reduced")
    basis_rows = np.asarray(basis_rows, dtype=np.float32)
    for _ in range(power_iterations):
        right = np.asarray(activations.T @ basis_rows, dtype=np.float32)
        sample = np.asarray(activations @ right, dtype=np.float32)
        basis_rows, _ = np.linalg.qr(sample, mode="reduced")
        basis_rows = np.asarray(basis_rows, dtype=np.float32)
    basis_coefficients = np.asarray(
        basis_rows.T @ activations, dtype=np.float32
    )
    return basis_rows, basis_coefficients


def relative_l2_rows(reference: np.ndarray, candidate: np.ndarray) -> np.ndarray:
    numerator = np.linalg.norm(reference - candidate, axis=1)
    denominator = np.maximum(np.linalg.norm(reference, axis=1), 1e-12)
    return np.asarray(numerator / denominator, dtype=np.float64)


def cosine_rows(reference: np.ndarray, candidate: np.ndarray) -> np.ndarray:
    numerator = np.sum(reference * candidate, axis=1, dtype=np.float64)
    denominator = np.linalg.norm(reference, axis=1) * np.linalg.norm(
        candidate, axis=1
    )
    both_zero = denominator <= 1e-24
    result = np.empty(reference.shape[0], dtype=np.float64)
    result[both_zero] = 1
    result[~both_zero] = numerator[~both_zero] / denominator[~both_zero]
    return np.clip(result, -1, 1)


def choose_sentinels(output_width: int, count: int, seed: int) -> np.ndarray:
    if count < 0 or count > output_width:
        raise ValueError("sentinel count is outside the output width")
    if count == 0:
        return np.empty(0, dtype=np.int64)
    rng = np.random.default_rng(seed)
    return np.sort(rng.choice(output_width, size=count, replace=False))


def choose_repairs(scores: np.ndarray, fraction: float) -> np.ndarray:
    if not 0 <= fraction <= 1:
        raise ValueError("repair fraction must be within [0, 1]")
    count = math.ceil(scores.size * fraction)
    if count == 0:
        return np.empty(0, dtype=np.int64)
    if count == scores.size:
        return np.arange(scores.size, dtype=np.int64)
    selected = np.argpartition(scores, scores.size - count)[-count:]
    return np.sort(selected.astype(np.int64, copy=False))


def percentile(values: np.ndarray, fraction: float) -> float:
    return float(np.quantile(values, fraction, method="linear"))


def output_metrics(
    *,
    activations: np.ndarray,
    weights: np.ndarray,
    basis_rows: np.ndarray,
    basis_coefficients: np.ndarray,
    basis_output: np.ndarray,
    repair_indices: np.ndarray,
    chunk_rows: int,
) -> tuple[dict[str, float], np.ndarray, dict[str, float]]:
    rows = activations.shape[0]
    if chunk_rows <= 0:
        raise ValueError("chunk_rows must be positive")
    repair_mask = np.zeros(rows, dtype=np.bool_)
    repair_mask[repair_indices] = True

    before_relative = np.empty(rows, dtype=np.float64)
    after_relative = np.empty(rows, dtype=np.float64)
    after_cosine = np.empty(rows, dtype=np.float64)
    squared_error = 0.0
    squared_reference = 0.0
    max_absolute_error = 0.0
    reference_seconds = 0.0
    candidate_seconds = 0.0
    scoring_seconds = 0.0

    for start in range(0, rows, chunk_rows):
        end = min(rows, start + chunk_rows)
        x = np.asarray(activations[start:end], dtype=np.float32)
        q = basis_rows[start:end]
        operation_started = time.perf_counter()
        reference = np.asarray(x @ weights, dtype=np.float32)
        reference_seconds += time.perf_counter() - operation_started
        operation_started = time.perf_counter()
        candidate = np.asarray(q @ basis_output, dtype=np.float32)
        candidate_seconds += time.perf_counter() - operation_started
        scoring_started = time.perf_counter()
        before_relative[start:end] = relative_l2_rows(reference, candidate)
        scoring_seconds += time.perf_counter() - scoring_started

        local_repairs = np.flatnonzero(repair_mask[start:end])
        if local_repairs.size:
            operation_started = time.perf_counter()
            reconstructed_input = q[local_repairs] @ basis_coefficients
            residual = x[local_repairs] - reconstructed_input
            candidate[local_repairs] += residual @ weights
            candidate_seconds += time.perf_counter() - operation_started

        scoring_started = time.perf_counter()
        difference = np.asarray(reference - candidate, dtype=np.float64)
        squared_error += float(np.sum(difference * difference))
        reference64 = np.asarray(reference, dtype=np.float64)
        squared_reference += float(np.sum(reference64 * reference64))
        max_absolute_error = max(
            max_absolute_error, float(np.max(np.abs(difference), initial=0))
        )
        after_relative[start:end] = relative_l2_rows(reference, candidate)
        after_cosine[start:end] = cosine_rows(reference, candidate)
        scoring_seconds += time.perf_counter() - scoring_started

    metrics = {
        "nrmse": math.sqrt(squared_error / max(squared_reference, 1e-24)),
        "mean_row_relative_l2": float(np.mean(after_relative)),
        "p95_row_relative_l2": percentile(after_relative, 0.95),
        "p99_row_relative_l2": percentile(after_relative, 0.99),
        "max_row_relative_l2": float(np.max(after_relative)),
        "p01_row_cosine": percentile(after_cosine, 0.01),
        "mean_row_cosine": float(np.mean(after_cosine)),
        "max_absolute_error": max_absolute_error,
    }
    return (
        metrics,
        before_relative,
        {
            "reference_projection_seconds": reference_seconds,
            "candidate_reconstruct_repair_seconds": candidate_seconds,
            "scoring_seconds": scoring_seconds,
        },
    )


def sentinel_recall(
    repair_indices: np.ndarray, oracle_scores: np.ndarray
) -> float:
    count = repair_indices.size
    if count == 0:
        return 1.0
    if count == oracle_scores.size:
        return 1.0
    oracle = np.argpartition(oracle_scores, oracle_scores.size - count)[-count:]
    overlap = np.intersect1d(repair_indices, oracle, assume_unique=False).size
    return overlap / count


def screen(
    *,
    candidate_mac_fraction: float,
    metrics: dict[str, float],
    repair_recall: float,
) -> dict[str, Any]:
    checks = {
        "arithmetic": (
            candidate_mac_fraction
            <= SCREEN_THRESHOLDS["maximum_candidate_mac_fraction"]
        ),
        "nrmse": metrics["nrmse"] <= SCREEN_THRESHOLDS["maximum_output_nrmse"],
        "row_error": (
            metrics["p99_row_relative_l2"]
            <= SCREEN_THRESHOLDS["maximum_p99_row_relative_l2"]
        ),
        "cosine": (
            metrics["p01_row_cosine"]
            >= SCREEN_THRESHOLDS["minimum_p01_row_cosine"]
        ),
        "sentinel_recall": (
            repair_recall
            >= SCREEN_THRESHOLDS["minimum_sentinel_worst_row_recall"]
        ),
    }
    return {
        "thresholds": SCREEN_THRESHOLDS,
        "checks": checks,
        "passes_projection_screen": all(checks.values()),
        "scope": "projection viability only; not a model quality or Mac speed pass",
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--synthetic", action="store_true")
    source.add_argument("--activations", type=Path)
    parser.add_argument("--weights", type=Path)
    parser.add_argument("--rank", type=int, required=True)
    parser.add_argument("--sentinels", type=int, default=16)
    parser.add_argument("--repair-fraction", type=float, default=0.10)
    parser.add_argument("--power-iterations", type=int, default=0)
    parser.add_argument("--seed", type=int, default=20260824)
    parser.add_argument("--chunk-rows", type=int, default=128)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--skip-input-hashes", action="store_true")
    parser.add_argument("--synthetic-rows", type=int, default=2048)
    parser.add_argument("--synthetic-input-width", type=int, default=256)
    parser.add_argument("--synthetic-output-width", type=int, default=1024)
    parser.add_argument("--synthetic-intrinsic-rank", type=int, default=8)
    parser.add_argument("--synthetic-noise", type=float, default=0.0001)
    return parser.parse_args()


def run(arguments: argparse.Namespace) -> dict[str, Any]:
    started = time.perf_counter()
    if arguments.synthetic:
        if arguments.weights is not None:
            raise ValueError("--weights is invalid with --synthetic")
        activations, weights = synthetic_matrices(
            rows=arguments.synthetic_rows,
            input_width=arguments.synthetic_input_width,
            output_width=arguments.synthetic_output_width,
            intrinsic_rank=arguments.synthetic_intrinsic_rank,
            noise=arguments.synthetic_noise,
            seed=arguments.seed,
        )
        source: dict[str, Any] = {
            "kind": "synthetic",
            "intrinsic_rank": arguments.synthetic_intrinsic_rank,
            "noise": arguments.synthetic_noise,
        }
    else:
        if arguments.weights is None:
            raise ValueError("--weights is required with --activations")
        activations = load_matrix(arguments.activations, "activations")
        weights = load_matrix(arguments.weights, "weights")
        source = {
            "kind": "npy",
            "activations": str(arguments.activations),
            "weights": str(arguments.weights),
        }
        if not arguments.skip_input_hashes:
            source["activation_sha256"] = sha256_file(arguments.activations)
            source["weight_sha256"] = sha256_file(arguments.weights)

    rows, input_width = activations.shape
    if weights.shape[0] != input_width:
        raise ValueError(
            "weights must use [input_width, output_width] orientation"
        )
    output_width = weights.shape[1]
    if arguments.repair_fraction > 0 and arguments.sentinels == 0:
        raise ValueError("sentinels are required when repair is enabled")

    basis_started = time.perf_counter()
    basis_rows, basis_coefficients = orthonormal_activation_basis(
        activations,
        rank=arguments.rank,
        power_iterations=arguments.power_iterations,
        seed=arguments.seed,
    )
    basis_seconds = time.perf_counter() - basis_started
    operation_started = time.perf_counter()
    basis_output = np.asarray(basis_coefficients @ weights, dtype=np.float32)
    basis_weight_seconds = time.perf_counter() - operation_started

    sentinel_indices = choose_sentinels(
        output_width, arguments.sentinels, arguments.seed + 1
    )
    operation_started = time.perf_counter()
    if sentinel_indices.size:
        sentinel_reference = np.asarray(
            activations @ weights[:, sentinel_indices], dtype=np.float32
        )
        sentinel_candidate = np.asarray(
            basis_rows @ basis_output[:, sentinel_indices],
            dtype=np.float32,
        )
        sentinel_scores = relative_l2_rows(
            sentinel_reference, sentinel_candidate
        )
    else:
        sentinel_scores = np.zeros(rows, dtype=np.float64)
    sentinel_seconds = time.perf_counter() - operation_started
    selection_started = time.perf_counter()
    repairs = choose_repairs(sentinel_scores, arguments.repair_fraction)
    selection_seconds = time.perf_counter() - selection_started

    metrics, oracle_scores, measured_wall = output_metrics(
        activations=activations,
        weights=weights,
        basis_rows=basis_rows,
        basis_coefficients=basis_coefficients,
        basis_output=basis_output,
        repair_indices=repairs,
        chunk_rows=arguments.chunk_rows,
    )
    repair_recall = sentinel_recall(repairs, oracle_scores)
    arithmetic = dense_budget(
        rows=rows,
        input_width=input_width,
        output_width=output_width,
        rank=arguments.rank,
        sentinel_columns=arguments.sentinels,
        repair_rows=repairs.size,
        power_iterations=arguments.power_iterations,
    )
    composition = b4_8k_composition(arithmetic.candidate_fraction)
    inclusive_candidate_seconds = (
        basis_seconds
        + basis_weight_seconds
        + sentinel_seconds
        + selection_seconds
        + measured_wall["candidate_reconstruct_repair_seconds"]
    )
    reference_seconds = measured_wall["reference_projection_seconds"]

    return {
        "schema_version": 1,
        "mechanism": "cohort-activation-subspace-sentinel-repair",
        "source": source,
        "shape": {
            "rows": rows,
            "input_width": input_width,
            "output_width": output_width,
        },
        "policy": {
            "rank": arguments.rank,
            "sentinel_columns": arguments.sentinels,
            "repair_fraction_limit": arguments.repair_fraction,
            "repair_rows": int(repairs.size),
            "power_iterations": arguments.power_iterations,
            "seed": arguments.seed,
        },
        "numerics": {
            **metrics,
            "sentinel_worst_row_recall": repair_recall,
        },
        "arithmetic": arithmetic.as_dict(),
        "uniform_model_composition": composition.as_dict(),
        "preregistered_model_schedule": preregistered_b4_schedule(),
        "screen": screen(
            candidate_mac_fraction=arithmetic.candidate_fraction,
            metrics=metrics,
            repair_recall=repair_recall,
        ),
        "wall": {
            "basis_seconds": basis_seconds,
            "basis_weight_projection_seconds": basis_weight_seconds,
            "sentinel_and_score_seconds": sentinel_seconds,
            "repair_selection_seconds": selection_seconds,
            **measured_wall,
            "inclusive_candidate_seconds": inclusive_candidate_seconds,
            "candidate_to_reference_ratio": (
                inclusive_candidate_seconds / reference_seconds
                if reference_seconds > 0
                else None
            ),
            "scope": (
                "NumPy/CPU process wall; includes candidate basis, sentinel, "
                "selection, reconstruction, and repair; excludes full-output "
                "oracle scoring from the candidate"
            ),
        },
        "probe_wall_seconds": time.perf_counter() - started,
    }


def main() -> None:
    arguments = parse_args()
    result = run(arguments)
    encoded = json.dumps(result, indent=2, sort_keys=True, allow_nan=False)
    if arguments.output is not None:
        arguments.output.write_text(encoded + "\n", encoding="utf-8")
    print(encoded)


if __name__ == "__main__":
    main()
