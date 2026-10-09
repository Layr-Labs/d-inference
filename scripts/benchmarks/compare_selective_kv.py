#!/usr/bin/env python3
"""Compare source-identical teacher-forced dense/half reports without a quality verdict."""
import argparse
import json
import math
from pathlib import Path


IDENTITIES = (
    "inputSHA256", "verifiedModelAggregateSHA256", "executableSHA256", "metallibSHA256",
)


def compare(dense: dict, selective: dict) -> dict:
    for key in IDENTITIES:
        if not isinstance(dense.get(key), str) or len(dense[key]) != 64 or dense[key] != selective.get(key):
            raise ValueError(f"mismatched or missing {key}")
    for report in (dense, selective):
        if (report.get("status") != "observed" or report.get("inconclusiveReasons") != []
                or report.get("resolvedBackend") != "contiguous" or report.get("concurrency") != 1
                or report.get("mtpEnabled") is not False or report.get("cacheMode") != "off"):
            raise ValueError("comparison requires conclusive, singleton, cache-off contiguous target reports")
        if report.get("scope") != "ordinary_teacher_forced_scores":
            raise ValueError("unsupported report scope")
        if not isinstance(report.get("peakMLXMemoryBytes"), int) or report["peakMLXMemoryBytes"] <= 0:
            raise ValueError("missing allocator peak")
        value = report.get("meanForcedTokenNLL")
        if not isinstance(value, (int, float)) or not math.isfinite(value):
            raise ValueError("nonfinite or missing NLL")
    capacity = dense.get("kvCapacityBytes")
    if isinstance(capacity, bool) or not isinstance(capacity, int) or capacity <= 0 or capacity != selective.get("kvCapacityBytes"):
        raise ValueError("mismatched or missing kvCapacityBytes")
    optimizations = dense.get("gemmaOptimizations")
    if not isinstance(optimizations, dict) or not optimizations or optimizations != selective.get("gemmaOptimizations"):
        raise ValueError("mismatched or missing gemmaOptimizations")
    if dense.get("kvQuantization") != selective.get("kvQuantization"):
        raise ValueError("mismatched kvQuantization")
    if dense.get("selectiveKVMode") != "0" or selective.get("selectiveKVMode") != "half":
        raise ValueError("expected an explicit dense control and half-retention candidate")
    stats = selective.get("selectiveKVStatistics") or {}
    if stats.get("pruningEvents", 0) <= 0 or stats.get("tokenEntriesRemoved", 0) <= 0:
        raise ValueError("candidate did not execute selective retention")
    before, after = stats.get("lastPruneSourceStorageBytes", 0), stats.get("lastPruneRetainedStorageBytes", 0)
    if not isinstance(before, int) or not isinstance(after, int) or not 0 < after < before:
        raise ValueError("candidate has no demonstrated logical storage reduction")
    original, candidate = dense.get("plainTop1"), selective.get("plainTop1")
    if not isinstance(original, list) or not isinstance(candidate, list) or not original or len(original) != len(candidate):
        raise ValueError("incomplete or mismatched scored continuations")
    return {
        "status": "observed",
        "scored_tokens": len(original),
        "top1_agreement": sum(a == b for a, b in zip(original, candidate)) / len(original),
        "mean_nll_delta": selective["meanForcedTokenNLL"] - dense["meanForcedTokenNLL"],
        "dense_peak_mlx_bytes": dense["peakMLXMemoryBytes"],
        "selective_peak_mlx_bytes": selective["peakMLXMemoryBytes"],
        "peak_mlx_bytes_delta": selective["peakMLXMemoryBytes"] - dense["peakMLXMemoryBytes"],
        "last_prune_logical_storage_ratio": after / before,
        "pruning_events": stats["pruningEvents"],
        "limitations": [
            "This reports a measured tradeoff; it does not qualify retention quality or serving.",
            "Allocator peaks include model and temporary allocations, not only retained KV.",
            "Logical source/retained extents do not prove physical page release.",
            "Teacher-forced scores do not replace long generation, tool, or retrieval evaluation.",
        ],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dense", type=Path)
    parser.add_argument("selective", type=Path)
    args = parser.parse_args()
    try:
        reports = [json.loads(path.read_text()) for path in (args.dense, args.selective)]
        print(json.dumps(compare(*reports), indent=2, allow_nan=False))
    except (OSError, ValueError, TypeError) as error:
        parser.exit(1, f"comparison refused: {error}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
