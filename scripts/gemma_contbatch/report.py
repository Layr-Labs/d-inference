"""Markdown rendering for benchmark reports."""

from __future__ import annotations

from .results import index_by


def format_number(value: float, digits: int = 1) -> str:
    return f"{value:,.{digits}f}"


def format_delta(value: float | None) -> str:
    return "n/a" if value is None else f"{value:+.2f}%"


def format_offsets(values: list[float | int], digits: int = 0) -> str:
    return " / ".join(f"{float(value):.{digits}f}" for value in values)


def arrival_fidelity_lines(summary: dict) -> list[str]:
    """Requested vs *delivered* arrival offsets, plus the retry evidence.

    The topology names only describe the run if the engine actually received
    requests on that schedule, so the measured offsets are reported next to the
    requested ones. `discardedAttempts` is a host-noise signal -- it is omitted
    entirely when every topology landed on the first attempt.
    """
    tolerance = summary["arrivalToleranceMs"]
    lines = [
        "",
        "## Arrival Timing Fidelity",
        "",
        f"Measured against a {tolerance:.2f} ms tolerance, up to "
        f"{summary['arrivalMaxAttemptsPerSample']} attempt(s) per sample.",
        "",
        "| Schedule | Requested (ms) | Measured (ms) | Max error | Within tolerance |",
        "|---|---|---|---:|---|",
    ]
    for item in summary["arrival"]:
        lines.append(
            f"| {item['name']} | {format_offsets(item['arrivalDelaysMs'])} "
            f"| {format_offsets(item['measuredArrivalOffsetsMs'], 1)} "
            f"| {item['maxArrivalErrorMs']:.2f} ms "
            f"| {'yes' if item['arrivalWithinTolerance'] else 'NO'} |"
        )
    discarded = [item for item in summary["arrival"] if item["discardedAttempts"]]
    if discarded:
        lines += [
            "",
            "Attempts discarded for missing the arrival tolerance (host scheduling noise):",
            "",
        ]
        for item in discarded:
            per_iteration = ", ".join(
                f"i={sample['iteration']}: {sample['discardedAttempts']}"
                for sample in item["samples"]
                if sample["discardedAttempts"]
            )
            lines.append(
                f"- {item['name']}: {item['discardedAttempts']} ({per_iteration})"
            )
    return lines


def lookup_comparison(
    comparisons: dict | None, section: str, key: str | int
) -> dict:
    if not comparisons:
        return {}
    lookup_key = {
        "prefill": "promptTokens",
        "schedulerTTFT": "promptTokens",
        "decode": "batchSize",
        "arrival": "name",
    }[section]
    return index_by(comparisons.get(section, []), lookup_key).get(key, {})


def kv_backend_lines(kv_backend: dict) -> list[str]:
    """Requested backend versus the one every decode cell actually built.

    Rendered as its own section rather than a configuration row because the
    selection is an input and the resolution is a result: an operator reading
    `paged` in the configuration table has been told what was asked for, not
    what was measured.
    """
    resolved = kv_backend["resolved"] or ["none"]
    lines = [
        "",
        "## KV Backend",
        "",
        "| Field | Value |",
        "|---|---|",
        f"| Requested | `{kv_backend['selection']}` |",
        f"| Resolved | `{'` + `'.join(resolved)}` |",
        f"| Descriptors | {', '.join(f'`{item}`' for item in kv_backend['resolvedDescriptors']) or 'none'} |",
    ]
    by_batch = kv_backend["byBatchSize"]
    if kv_backend["degrades"]:
        # The only place a reader learns WHY paged was not served: kill
        # switch, kernel preflight, pool capacity, or a binary copied without
        # its `pagedattention.metal` resource bundle.
        lines.append(
            f"| Degraded because | {'; '.join(kv_backend['degrades'])} |"
        )
    if by_batch:
        per_cell = ", ".join(
            f"B={batch}: `{kind}`"
            for batch, kind in sorted(by_batch.items(), key=lambda kv: int(kv[0]))
        )
        lines.append(f"| Per batch size | {per_cell} |")
    return lines


def markdown_report(report: dict) -> str:
    summary = report["summary"]
    metadata = report["metadata"]
    configuration = report["configuration"]
    comparisons = report.get("comparison")
    kv_backend = report["kvBackend"]
    violations = kv_backend["postureViolations"]
    hardware = report["raw"]["throughputSweep"]["hardware"]
    model_path = report["raw"]["throughputSweep"]["modelPath"]
    dirty = metadata["gitStatus"] or ["clean"]
    dirty_value = "<br>".join(dirty)

    lines = [
        "# Gemma Continuous-Batching Benchmark",
        "",
        "| Field | Value |",
        "|---|---|",
        f"| Generated | {report['generatedAt']} |",
        f"| Label | {report.get('label') or 'unlabeled'} |",
        f"| Model | `{report['modelID']}` |",
        f"| Model snapshot | `{report['modelSnapshot']}` |",
        f"| Model path | `{model_path}` |",
        f"| Hardware | {hardware['chipName']}, {hardware['gpuCores']} GPU cores, {hardware['memoryGb']} GB |",
        f"| Root commit | `{metadata['rootCommit']}` |",
        f"| Binary SHA-256 | `{metadata['binarySha256']}` |",
        f"| Metallib SHA-256 | `{metadata['metallibSha256']}` |",
        f"| Working tree | {dirty_value} |",
        f"| Duration | {format_number(report['durationSeconds'], 1)} seconds |",
        "",
        "## Configuration",
        "",
        "| Setting | Value |",
        "|---|---:|",
        f"| Iterations | {configuration['iterations']} |",
        f"| Prefill lengths | {', '.join(map(str, configuration['prefillLengths']))} |",
        f"| Decode prompt / output | {configuration['decodePromptTokens']} / {configuration['decodeTokens']} tokens |",
        f"| Decode batch sizes | {', '.join(map(str, configuration['batchSizes']))} |",
        f"| Decode samples per batch | {configuration['decodeIterations']} |",
        f"| Arrival prompt / output | {configuration['arrivalPromptTokens']} / {configuration['arrivalDecodeTokens']} tokens |",
    ]

    lines += kv_backend_lines(kv_backend)

    lines += [
        "",
        "## Raw Prefill",
        "",
        "| Prompt | Median elapsed | Median tok/s | vs baseline tok/s |",
        "|---:|---:|---:|---:|",
    ]
    for item in summary["prefill"]:
        delta = lookup_comparison(
            comparisons, "prefill", item["promptTokens"]
        ).get("tokensPerSecondPercent")
        lines.append(
            f"| {item['promptTokens']:,} | {format_number(item['medianElapsedMs'])} ms "
            f"| {format_number(item['medianTokensPerSecond'])} | {format_delta(delta)} |"
        )

    lines += [
        "",
        "## Production TTFT",
        "",
        "| Prompt | Median TTFT | vs baseline |",
        "|---:|---:|---:|",
    ]
    for item in summary["schedulerTTFT"]:
        delta = lookup_comparison(
            comparisons, "schedulerTTFT", item["promptTokens"]
        ).get("ttftMsPercent")
        lines.append(
            f"| {item['promptTokens']:,} | {format_number(item['medianTTFTMs'])} ms "
            f"| {format_delta(delta)} |"
        )

    lines += [
        "",
        "## Decode Batch Curve",
        "",
        "| Batch | Samples | Median per-request tok/s | Median aggregate tok/s | Aggregate vs baseline |",
        "|---:|---:|---:|---:|---:|",
    ]
    for item in summary["decode"]:
        delta = lookup_comparison(
            comparisons, "decode", item["batchSize"]
        ).get("aggregatePercent")
        lines.append(
            f"| {item['batchSize']} | {item['sampleCount']} "
            f"| {format_number(item['perRequestTokensPerSecond'])} "
            f"| {format_number(item['aggregateTokensPerSecond'])} | {format_delta(delta)} |"
        )

    lines += [
        "",
        "## Arrival Schedules",
        "",
        "| Schedule | Median TTFT | Decode-window TPS | End-to-end TPS | Makespan | E2E vs baseline |",
        "|---|---:|---:|---:|---:|---:|",
    ]
    for item in summary["arrival"]:
        delta = lookup_comparison(comparisons, "arrival", item["name"]).get(
            "endToEndPercent"
        )
        delays = "/".join(map(str, item["arrivalDelaysMs"]))
        lines.append(
            f"| {item['name']} ({delays} ms) | {format_number(item['medianTTFTMs'])} ms "
            f"| {format_number(item['medianAggregateDecodeTokensPerSecond'])} "
            f"| {format_number(item['medianEndToEndTokensPerSecond'])} "
            f"| {format_number(item['medianMakespanMs'])} ms | {format_delta(delta)} |"
        )

    lines += arrival_fidelity_lines(summary)

    lines += [
        "",
        "## Per-Row Arrival Detail",
        "",
        "| Schedule | Row | Requested arrival | Measured arrival | Median TTFT | Median decode tok/s |",
        "|---|---:|---:|---:|---:|---:|",
    ]
    for item in summary["arrival"]:
        for row in item["rows"]:
            index = row["row"]
            lines.append(
                f"| {item['name']} | {index} | {item['arrivalDelaysMs'][index]} ms "
                f"| {format_number(item['measuredArrivalOffsetsMs'][index], 2)} ms "
                f"| {format_number(row['medianTTFTMs'])} ms "
                f"| {format_number(row['medianDecodeTokensPerSecond'])} |"
            )

    invariant = all(
        item["outputsStableAcrossIterations"] and item["outputsMatchBurst"]
        for item in summary["arrival"]
    )
    arrivals_delivered = all(
        item["arrivalWithinTolerance"] for item in summary["arrival"]
    )
    worst_arrival_error = max(
        (item["maxArrivalErrorMs"] for item in summary["arrival"]), default=0.0
    )
    lines += [
        "",
        "## Validation",
        "",
        f"- Exact output invariance: {'PASS' if invariant else 'FAIL'}",
        f"- KV backend posture: {'PASS' if not violations else 'FAIL'} "
        + (
            f"(requested `{kv_backend['selection']}`, measured "
            f"`{'` + `'.join(kv_backend['resolved']) or 'none'}`)"
            if not violations
            else "— " + "; ".join(violations)
        ),
        f"- Delivered arrival topology: {'PASS' if arrivals_delivered else 'FAIL'} "
        f"(worst arrival error {worst_arrival_error:.2f} ms against a "
        f"{summary['arrivalToleranceMs']:.2f} ms tolerance)",
        f"- Thermal state before: {metadata['thermalBefore'].replace(chr(10), '; ')}",
        f"- Thermal state after: {metadata['thermalAfter'].replace(chr(10), '; ')}",
        "",
        "Decode-window TPS spans the earliest first token through the latest last token, so staggered schedules include later prefills and low-concurrency gaps. End-to-end TPS is all output tokens divided by total makespan.",
        "",
        "Arrival offsets are measured at submission against absolute deadlines, so every schedule above is the one the engine actually received, not the one that was requested.",
        "",
        "The complete raw benchmark payload and every repetition are in the companion JSON report.",
        "",
    ]
    return "\n".join(lines)
