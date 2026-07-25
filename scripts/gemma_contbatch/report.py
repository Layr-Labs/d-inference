"""Markdown rendering for benchmark reports."""

from __future__ import annotations

from .results import index_by


def format_number(value: float, digits: int = 1) -> str:
    return f"{value:,.{digits}f}"


def format_delta(value: float | None) -> str:
    return "n/a" if value is None else f"{value:+.2f}%"


def lookup_comparison(comparisons: dict | None, section: str, key: str) -> dict:
    if not comparisons:
        return {}
    lookup_key = {
        "prefill": "promptTokens",
        "schedulerTTFT": "promptTokens",
        "decode": "batchSize",
        "arrival": "name",
    }[section]
    return index_by(comparisons.get(section, []), lookup_key).get(key, {})


def markdown_report(report: dict) -> str:
    summary = report["summary"]
    metadata = report["metadata"]
    configuration = report["configuration"]
    comparisons = report.get("comparison")
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
        f"| Maximum decode batch | {configuration['maxBatch']} |",
        f"| Arrival prompt / output | {configuration['arrivalPromptTokens']} / {configuration['arrivalDecodeTokens']} tokens |",
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
        "| Batch | Per-request tok/s | Aggregate tok/s | Aggregate vs baseline |",
        "|---:|---:|---:|---:|",
    ]
    for item in summary["decode"]:
        delta = lookup_comparison(
            comparisons, "decode", item["batchSize"]
        ).get("aggregatePercent")
        lines.append(
            f"| {item['batchSize']} | {format_number(item['perRequestTokensPerSecond'])} "
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

    lines += [
        "",
        "## Per-Row Arrival Detail",
        "",
        "| Schedule | Row | Median TTFT | Median decode tok/s |",
        "|---|---:|---:|---:|",
    ]
    for item in summary["arrival"]:
        for row in item["rows"]:
            lines.append(
                f"| {item['name']} | {row['row']} | {format_number(row['medianTTFTMs'])} ms "
                f"| {format_number(row['medianDecodeTokensPerSecond'])} |"
            )

    invariant = all(
        item["outputsStableAcrossIterations"] and item["outputsMatchBurst"]
        for item in summary["arrival"]
    )
    lines += [
        "",
        "## Validation",
        "",
        f"- Exact output invariance: {'PASS' if invariant else 'FAIL'}",
        f"- Thermal state before: {metadata['thermalBefore'].replace(chr(10), '; ')}",
        f"- Thermal state after: {metadata['thermalAfter'].replace(chr(10), '; ')}",
        "",
        "Decode-window TPS spans the earliest first token through the latest last token, so staggered schedules include later prefills and low-concurrency gaps. End-to-end TPS is all output tokens divided by total makespan.",
        "",
        "The complete raw benchmark payload and every repetition are in the companion JSON report.",
        "",
    ]
    return "\n".join(lines)
