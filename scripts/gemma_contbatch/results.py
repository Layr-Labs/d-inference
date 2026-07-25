"""Benchmark summaries, baseline comparisons, and comparison validation."""

from __future__ import annotations

import argparse
from collections import defaultdict
from statistics import median


def summarize(sweep: dict, scheduler: dict, arrival: dict) -> dict:
    prefill_groups: dict[int, list[dict]] = defaultdict(list)
    for sample in sweep["prefill"]:
        prefill_groups[int(sample["promptTokens"])].append(sample)
    prefill = []
    for prompt_tokens, samples in sorted(prefill_groups.items()):
        prefill.append(
            {
                "promptTokens": prompt_tokens,
                "medianElapsedMs": median(item["elapsedMs"] for item in samples),
                "medianTokensPerSecond": median(
                    item["prefillTokensPerSecond"] for item in samples
                ),
                "samples": [
                    {
                        "elapsedMs": item["elapsedMs"],
                        "tokensPerSecond": item["prefillTokensPerSecond"],
                    }
                    for item in samples
                ],
            }
        )

    ttft_groups: dict[int, list[dict]] = defaultdict(list)
    for sample in scheduler["samples"]:
        ttft_groups[int(sample["promptTokens"])].append(sample)
    scheduler_ttft = []
    for prompt_tokens, samples in sorted(ttft_groups.items()):
        scheduler_ttft.append(
            {
                "promptTokens": prompt_tokens,
                "medianTTFTMs": median(item["ttftMs"] for item in samples),
                "samples": [
                    {
                        "ttftMs": item["ttftMs"],
                        "msPerPrefillToken": item["msPerPrefillToken"],
                    }
                    for item in samples
                ],
            }
        )

    decode = [
        {
            "batchSize": item["batchSize"],
            "elapsedMs": item["elapsedMs"],
            "perRequestTokensPerSecond": item["perSequenceTokensPerSecond"],
            "aggregateTokensPerSecond": item["aggregateTokensPerSecond"],
        }
        for item in sweep["decode"]
    ]

    arrival_summary = []
    for pattern in arrival["patterns"]:
        all_rows = [row for sample in pattern["samples"] for row in sample["rows"]]
        row_groups: dict[int, list[dict]] = defaultdict(list)
        for sample in pattern["samples"]:
            for row in sample["rows"]:
                row_groups[int(row["row"])].append(row)
        rows = [
            {
                "row": row,
                "medianTTFTMs": median(item["ttftMs"] for item in samples),
                "medianDecodeTokensPerSecond": median(
                    item["decodeTokensPerSecond"] for item in samples
                ),
            }
            for row, samples in sorted(row_groups.items())
        ]
        arrival_summary.append(
            {
                "name": pattern["name"],
                "arrivalDelaysMs": pattern["arrivalDelaysMs"],
                "medianTTFTMs": median(row["ttftMs"] for row in all_rows),
                "medianPerRequestDecodeTokensPerSecond": median(
                    row["decodeTokensPerSecond"] for row in all_rows
                ),
                "medianAggregateDecodeTokensPerSecond": median(
                    item["aggregateDecodeTokensPerSecond"]
                    for item in pattern["samples"]
                ),
                "medianEndToEndTokensPerSecond": median(
                    item["endToEndTokensPerSecond"] for item in pattern["samples"]
                ),
                "medianMakespanMs": median(
                    item["makespanMs"] for item in pattern["samples"]
                ),
                "outputsStableAcrossIterations": pattern[
                    "outputsStableAcrossIterations"
                ],
                "outputsMatchBurst": pattern["outputsMatchBurst"],
                "samples": [
                    {
                        "iteration": item["iteration"],
                        "aggregateDecodeTokensPerSecond": item[
                            "aggregateDecodeTokensPerSecond"
                        ],
                        "endToEndTokensPerSecond": item["endToEndTokensPerSecond"],
                        "makespanMs": item["makespanMs"],
                    }
                    for item in pattern["samples"]
                ],
                "rows": rows,
            }
        )

    return {
        "prefill": prefill,
        "schedulerTTFT": scheduler_ttft,
        "decode": decode,
        "arrival": arrival_summary,
    }


def index_by(items: list[dict], key: str) -> dict:
    return {item[key]: item for item in items}


def percent_delta(current: float, baseline: float) -> float | None:
    if baseline == 0:
        return None
    return (current / baseline - 1.0) * 100.0


def compare(current: dict, baseline: dict) -> dict:
    baseline_summary = baseline["summary"]
    comparisons: dict[str, object] = {"baselineName": baseline.get("name", "baseline")}

    base_prefill = index_by(baseline_summary["prefill"], "promptTokens")
    comparisons["prefill"] = [
        {
            "promptTokens": item["promptTokens"],
            "tokensPerSecondPercent": percent_delta(
                item["medianTokensPerSecond"],
                base_prefill[item["promptTokens"]]["medianTokensPerSecond"],
            ),
            "elapsedMsPercent": percent_delta(
                item["medianElapsedMs"],
                base_prefill[item["promptTokens"]]["medianElapsedMs"],
            ),
        }
        for item in current["prefill"]
        if item["promptTokens"] in base_prefill
    ]

    base_ttft = index_by(baseline_summary["schedulerTTFT"], "promptTokens")
    comparisons["schedulerTTFT"] = [
        {
            "promptTokens": item["promptTokens"],
            "ttftMsPercent": percent_delta(
                item["medianTTFTMs"],
                base_ttft[item["promptTokens"]]["medianTTFTMs"],
            ),
        }
        for item in current["schedulerTTFT"]
        if item["promptTokens"] in base_ttft
    ]

    base_decode = index_by(baseline_summary["decode"], "batchSize")
    comparisons["decode"] = [
        {
            "batchSize": item["batchSize"],
            "perRequestPercent": percent_delta(
                item["perRequestTokensPerSecond"],
                base_decode[item["batchSize"]]["perRequestTokensPerSecond"],
            ),
            "aggregatePercent": percent_delta(
                item["aggregateTokensPerSecond"],
                base_decode[item["batchSize"]]["aggregateTokensPerSecond"],
            ),
        }
        for item in current["decode"]
        if item["batchSize"] in base_decode
    ]

    base_arrival = index_by(baseline_summary["arrival"], "name")
    comparisons["arrival"] = [
        {
            "name": item["name"],
            "ttftMsPercent": percent_delta(
                item["medianTTFTMs"], base_arrival[item["name"]]["medianTTFTMs"]
            ),
            "aggregateDecodePercent": percent_delta(
                item["medianAggregateDecodeTokensPerSecond"],
                base_arrival[item["name"]][
                    "medianAggregateDecodeTokensPerSecond"
                ],
            ),
            "endToEndPercent": percent_delta(
                item["medianEndToEndTokensPerSecond"],
                base_arrival[item["name"]]["medianEndToEndTokensPerSecond"],
            ),
            "makespanPercent": percent_delta(
                item["medianMakespanMs"],
                base_arrival[item["name"]]["medianMakespanMs"],
            ),
        }
        for item in current["arrival"]
        if item["name"] in base_arrival
    ]
    return comparisons


def validate_comparison_shape(args: argparse.Namespace, baseline: dict) -> None:
    baseline_configuration = baseline.get("configuration", {})
    expected = {
        "decodePromptTokens": args.decode_prompt_tokens,
        "decodeTokens": args.decode_tokens,
        "arrivalPromptTokens": args.arrival_prompt_tokens,
        "arrivalDecodeTokens": args.arrival_decode_tokens,
    }
    mismatches = [
        f"{key}={value} (baseline {baseline_configuration.get(key)})"
        for key, value in expected.items()
        if baseline_configuration.get(key) != value
    ]
    if mismatches:
        raise RuntimeError(
            "benchmark shape is not comparable to the baseline: "
            + ", ".join(mismatches)
            + "; pass --no-compare for a different workload"
        )
