"""Per-benchmark median summaries of the raw benchmark payloads.

Every headline number in the summary is a median over the repetitions that
were actually measured; the raw per-repetition samples are kept alongside it
so a reader can see the spread the median came from.
"""

from __future__ import annotations

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

    # The decode curve is repeated once per iteration (`--decode-iterations`),
    # so every batch size carries N samples and the headline numbers are real
    # medians -- never a single GPU measurement relabelled as one.
    decode_groups: dict[int, list[dict]] = defaultdict(list)
    for sample in sweep["decode"]:
        decode_groups[int(sample["batchSize"])].append(sample)
    decode = [
        {
            "batchSize": batch_size,
            "sampleCount": len(samples),
            "elapsedMs": median(item["elapsedMs"] for item in samples),
            "perRequestTokensPerSecond": median(
                item["perSequenceTokensPerSecond"] for item in samples
            ),
            "aggregateTokensPerSecond": median(
                item["aggregateTokensPerSecond"] for item in samples
            ),
            "samples": [
                {
                    "elapsedMs": item["elapsedMs"],
                    "perRequestTokensPerSecond": item["perSequenceTokensPerSecond"],
                    "aggregateTokensPerSecond": item["aggregateTokensPerSecond"],
                }
                for item in samples
            ],
        }
        for batch_size, samples in sorted(decode_groups.items())
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
                # Measured evidence that the arrivals were the named topology,
                # carried into the summary so the report shows what was
                # delivered next to what was requested.
                "measuredArrivalOffsetsMs": pattern["measuredArrivalOffsetsMs"],
                "maxArrivalErrorMs": pattern["maxArrivalErrorMs"],
                "arrivalWithinTolerance": pattern["arrivalWithinTolerance"],
                "discardedAttempts": sum(
                    int(item["discardedAttempts"]) for item in pattern["samples"]
                ),
                "samples": [
                    {
                        "iteration": item["iteration"],
                        "aggregateDecodeTokensPerSecond": item[
                            "aggregateDecodeTokensPerSecond"
                        ],
                        "endToEndTokensPerSecond": item["endToEndTokensPerSecond"],
                        "makespanMs": item["makespanMs"],
                        "maxArrivalErrorMs": item["maxArrivalErrorMs"],
                        "discardedAttempts": item["discardedAttempts"],
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
        "arrivalToleranceMs": arrival["arrivalToleranceMs"],
        "arrivalMaxAttemptsPerSample": arrival["arrivalMaxAttemptsPerSample"],
    }
