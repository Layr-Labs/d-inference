"""Baseline comparison of a summary against the committed baseline."""

from __future__ import annotations

from .baseline import NO_COMPARE_HINT


def index_by(items: list[dict], key: str) -> dict:
    return {item[key]: item for item in items}


def percent_delta(current: float, baseline: float) -> float | None:
    if baseline == 0:
        return None
    return (current / baseline - 1.0) * 100.0


def index_against_baseline(
    section: str, current_items: list[dict], baseline_items: list[dict], key: str
) -> dict:
    """Index the baseline section, refusing any partial overlap.

    A comparison that silently skips the rows the baseline happens to be missing
    is worse than no comparison: the report still claims to be a baseline diff
    while quietly hiding whichever measurements moved the most.
    """
    baseline_index = index_by(baseline_items, key)
    current_keys = [item[key] for item in current_items]
    duplicates = sorted(
        {value for value in current_keys if current_keys.count(value) > 1}, key=repr
    )
    absent_from_baseline = sorted(
        {value for value in current_keys if value not in baseline_index},
        key=repr,
    )
    absent_from_run = sorted(set(baseline_index) - set(current_keys), key=repr)
    problems = []
    if len(baseline_index) != len(baseline_items):
        problems.append(f"duplicate {key} in the baseline")
    if duplicates:
        problems.append(f"duplicate {key} in this run: {duplicates}")
    if absent_from_baseline:
        problems.append(f"{key} missing from the baseline: {absent_from_baseline}")
    if absent_from_run:
        problems.append(f"{key} missing from this run: {absent_from_run}")
    if problems:
        raise RuntimeError(
            f"baseline {section} shape does not match this run ("
            + "; ".join(problems)
            + "); "
            + NO_COMPARE_HINT
        )
    return baseline_index


def compare(current: dict, baseline: dict) -> dict:
    baseline_summary = baseline["summary"]
    comparisons: dict[str, object] = {"baselineName": baseline.get("name", "baseline")}

    base_prefill = index_against_baseline(
        "prefill", current["prefill"], baseline_summary["prefill"], "promptTokens"
    )
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
    ]

    base_ttft = index_against_baseline(
        "schedulerTTFT",
        current["schedulerTTFT"],
        baseline_summary["schedulerTTFT"],
        "promptTokens",
    )
    comparisons["schedulerTTFT"] = [
        {
            "promptTokens": item["promptTokens"],
            "ttftMsPercent": percent_delta(
                item["medianTTFTMs"],
                base_ttft[item["promptTokens"]]["medianTTFTMs"],
            ),
        }
        for item in current["schedulerTTFT"]
    ]

    base_decode = index_against_baseline(
        "decode", current["decode"], baseline_summary["decode"], "batchSize"
    )
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
    ]

    base_arrival = index_against_baseline(
        "arrival", current["arrival"], baseline_summary["arrival"], "name"
    )
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
    ]
    return comparisons
