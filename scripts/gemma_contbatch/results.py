"""Baseline comparison against an explicitly supplied, validated report."""

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

    # Each section names its row identity and its output-to-source metric map.
    # Keep this order: a malformed earlier section must still fail first.
    for section, key, metrics in (
        ("prefill", "promptTokens", {
            "tokensPerSecondPercent": "medianTokensPerSecond",
            "elapsedMsPercent": "medianElapsedMs",
        }),
        ("schedulerTTFT", "promptTokens", {"ttftMsPercent": "medianTTFTMs"}),
        ("decode", "batchSize", {
            "perRequestPercent": "perRequestTokensPerSecond",
            "aggregatePercent": "aggregateTokensPerSecond",
        }),
        ("arrival", "name", {
            "ttftMsPercent": "medianTTFTMs",
            "aggregateDecodePercent": "medianAggregateDecodeTokensPerSecond",
            "endToEndPercent": "medianEndToEndTokensPerSecond",
            "makespanPercent": "medianMakespanMs",
        }),
    ):
        reference = index_against_baseline(
            section, current[section], baseline_summary[section], key
        )
        comparisons[section] = [
            {
                key: item[key],
                **{
                    output: percent_delta(item[source], reference[item[key]][source])
                    for output, source in metrics.items()
                },
            }
            for item in current[section]
        ]
    return comparisons
