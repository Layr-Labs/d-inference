#!/usr/bin/env python3
"""Run the frozen E50 GDN-output rank/repair neighborhood."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from types import SimpleNamespace
from typing import Any

import probe


PREREGISTERED_RANKS = (32, 48, 64, 80, 96)
PREREGISTERED_REPAIR_FRACTIONS = (0.08, 0.10, 0.12, 0.15)
PREREGISTERED_SENTINELS = 16


def parse_csv(raw: str, conversion: Any) -> list[Any]:
    values = [conversion(value.strip()) for value in raw.split(",") if value.strip()]
    if not values:
        raise ValueError("sweep lists must not be empty")
    return values


def summary_row(result: dict[str, Any]) -> dict[str, Any]:
    return {
        "rank": result["policy"]["rank"],
        "sentinel_columns": result["policy"]["sentinel_columns"],
        "repair_fraction_limit": result["policy"]["repair_fraction_limit"],
        "repair_rows": result["policy"]["repair_rows"],
        "candidate_mac_fraction": result["arithmetic"]["candidate_fraction"],
        "modeled_uniform_native_speedup": result["uniform_model_composition"][
            "native_speedup"
        ],
        "nrmse": result["numerics"]["nrmse"],
        "p99_row_relative_l2": result["numerics"]["p99_row_relative_l2"],
        "p01_row_cosine": result["numerics"]["p01_row_cosine"],
        "mean_row_cosine": result["numerics"]["mean_row_cosine"],
        "sentinel_worst_row_recall": result["numerics"][
            "sentinel_worst_row_recall"
        ],
        "inclusive_candidate_seconds": result["wall"][
            "inclusive_candidate_seconds"
        ],
        "reference_projection_seconds": result["wall"][
            "reference_projection_seconds"
        ],
        "candidate_to_reference_wall_ratio": result["wall"][
            "candidate_to_reference_ratio"
        ],
        "probe_wall_seconds": result["probe_wall_seconds"],
        "checks": result["screen"]["checks"],
        "passes_projection_screen": result["screen"]["passes_projection_screen"],
    }


def run_sweep(
    *,
    activations: Path,
    weights: Path,
    output_directory: Path,
    ranks: list[int],
    repair_fractions: list[float],
    sentinels: int,
    power_iterations: int,
    seed: int,
    chunk_rows: int,
) -> dict[str, Any]:
    output_directory.mkdir(parents=True, exist_ok=True)
    rows: list[dict[str, Any]] = []
    for rank in ranks:
        for repair_fraction in repair_fractions:
            label = f"r{rank:03d}-p{round(repair_fraction * 100):02d}"
            print(f"[e50-sweep] {label}", file=sys.stderr, flush=True)
            arguments = SimpleNamespace(
                synthetic=False,
                activations=activations,
                weights=weights,
                rank=rank,
                sentinels=sentinels,
                repair_fraction=repair_fraction,
                power_iterations=power_iterations,
                seed=seed,
                chunk_rows=chunk_rows,
                output=output_directory / f"{label}.json",
                skip_input_hashes=True,
                synthetic_rows=0,
                synthetic_input_width=0,
                synthetic_output_width=0,
                synthetic_intrinsic_rank=0,
                synthetic_noise=0,
            )
            result = probe.run(arguments)
            arguments.output.write_text(
                json.dumps(result, indent=2, sort_keys=True, allow_nan=False)
                + "\n",
                encoding="utf-8",
            )
            row = summary_row(result)
            row["result"] = arguments.output.name
            rows.append(row)

    registered = next(
        (
            row
            for row in rows
            if row["rank"] == 64
            and row["repair_fraction_limit"] == 0.12
        ),
        None,
    )
    result = {
        "schema_version": 1,
        "mechanism": "e50-activation-subspace-sentinel-repair",
        "projection": "model.layers.12.linear_attn.out_proj",
        "input": {
            "activations": str(activations),
            "weights": str(weights),
        },
        "neighborhood": {
            "ranks": ranks,
            "repair_fractions": repair_fractions,
            "sentinel_columns": sentinels,
            "power_iterations": power_iterations,
            "seed": seed,
            "chunk_rows": chunk_rows,
        },
        "registered_cell": registered,
        "pass_count": sum(row["passes_projection_screen"] for row in rows),
        "cell_count": len(rows),
        "cells": rows,
    }
    (output_directory / "summary.json").write_text(
        json.dumps(result, indent=2, sort_keys=True, allow_nan=False) + "\n",
        encoding="utf-8",
    )
    return result


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--activations", type=Path, required=True)
    parser.add_argument("--weights", type=Path, required=True)
    parser.add_argument("--output-directory", type=Path, required=True)
    parser.add_argument(
        "--ranks", default=",".join(str(value) for value in PREREGISTERED_RANKS)
    )
    parser.add_argument(
        "--repair-fractions",
        default=",".join(
            str(value) for value in PREREGISTERED_REPAIR_FRACTIONS
        ),
    )
    parser.add_argument("--sentinels", type=int, default=PREREGISTERED_SENTINELS)
    parser.add_argument("--power-iterations", type=int, default=0)
    parser.add_argument("--seed", type=int, default=20260824)
    parser.add_argument("--chunk-rows", type=int, default=128)
    return parser.parse_args()


def main() -> None:
    arguments = parse_args()
    result = run_sweep(
        activations=arguments.activations,
        weights=arguments.weights,
        output_directory=arguments.output_directory,
        ranks=parse_csv(arguments.ranks, int),
        repair_fractions=parse_csv(arguments.repair_fractions, float),
        sentinels=arguments.sentinels,
        power_iterations=arguments.power_iterations,
        seed=arguments.seed,
        chunk_rows=arguments.chunk_rows,
    )
    print(json.dumps(result, indent=2, sort_keys=True, allow_nan=False))


if __name__ == "__main__":
    main()
