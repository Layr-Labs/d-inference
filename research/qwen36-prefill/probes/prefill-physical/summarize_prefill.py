#!/usr/bin/env python3
"""Emit stable one-line summaries from an arrival-invariance report."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


def field_safe(value: object) -> str:
    return "_".join(str(value).split())


def require_number(value: Any, name: str) -> float:
    if not isinstance(value, (int, float)):
        raise ValueError(f"{name} must be numeric")
    return float(value)


def summarize(report: dict[str, Any]) -> list[str]:
    batch = int(report["batchSize"])
    prompt = int(report["promptTokensPerRequest"])
    iterations = int(report["iterations"])
    model = field_safe(report["modelID"])
    resolved = report["kvBackend"]["resolved"]
    if batch not in {1, 2, 4}:
        raise ValueError(f"unexpected batch size {batch}")
    if not isinstance(resolved, list) or resolved != ["contiguous"]:
        raise ValueError(f"expected contiguous KV, found {resolved!r}")
    patterns = report["patterns"]
    if not isinstance(patterns, list) or not patterns:
        raise ValueError("report has no arrival patterns")
    if patterns[0].get("name") != "burst":
        raise ValueError("burst must be the first arrival pattern")

    lines = [
        "PREFILL_REPORT"
        f" schema={int(report['schemaVersion'])}"
        f" model={model}"
        f" batch={batch}"
        f" prompt_tokens_per_request={prompt}"
        f" requested_prompt_tokens={batch * prompt}"
        f" iterations={iterations}"
        " kv_backend=contiguous"
        " prefix_cache=off"
        " numerical_posture=strict_default_top8",
    ]
    for pattern in patterns:
        samples = pattern["samples"]
        if len(samples) != iterations:
            raise ValueError(
                f"{pattern['name']} has {len(samples)} samples; {iterations} expected"
            )
        sample_tps = [
            require_number(
                sample["aggregatePrefillTokensPerSecond"],
                "aggregatePrefillTokensPerSecond",
            )
            for sample in samples
        ]
        sample_ms = [
            require_number(sample["prefillMakespanMs"], "prefillMakespanMs")
            for sample in samples
        ]
        lines.append(
            "PREFILL_PATTERN"
            f" name={field_safe(pattern['name'])}"
            f" median_aggregate_tps="
            f"{require_number(pattern['medianAggregatePrefillTokensPerSecond'], 'medianAggregatePrefillTokensPerSecond'):.3f}"
            f" median_prefill_ms="
            f"{require_number(pattern['medianPrefillMakespanMs'], 'medianPrefillMakespanMs'):.3f}"
            f" median_ttft_ms="
            f"{require_number(pattern['medianTTFTMs'], 'medianTTFTMs'):.3f}"
            f" min_sample_tps={min(sample_tps):.3f}"
            f" max_sample_tps={max(sample_tps):.3f}"
            f" min_sample_ms={min(sample_ms):.3f}"
            f" max_sample_ms={max(sample_ms):.3f}"
            f" arrival_within_tolerance="
            f"{str(bool(pattern['arrivalWithinTolerance'])).lower()}"
            f" outputs_stable="
            f"{str(bool(pattern['outputsStableAcrossIterations'])).lower()}"
            f" first_tokens_stable="
            f"{str(bool(pattern.get('firstTokensStableAcrossIterations', False))).lower()}"
        )
    return lines


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("report", type=Path)
    return parser.parse_args()


def main() -> None:
    arguments = parse_args()
    with arguments.report.open(encoding="utf-8") as handle:
        report = json.load(handle)
    for line in summarize(report):
        print(line)


if __name__ == "__main__":
    main()
