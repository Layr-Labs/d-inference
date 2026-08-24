#!/usr/bin/env python3
"""Summarize unprivileged AGX and xctrace telemetry from an MPP soak."""

from __future__ import annotations

import argparse
import collections
import json
import math
import statistics
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Iterable


def number(value: str | None) -> float | None:
    if value is None:
        return None
    try:
        return float(value)
    except ValueError:
        return None


def percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    index = round(fraction * (len(ordered) - 1))
    return ordered[max(0, min(len(ordered) - 1, index))]


def fmt(value: float, digits: int = 3) -> str:
    return f"{value:.{digits}f}"


class TraceTable:
    def __init__(self, path: Path) -> None:
        self.path = path
        self.exists = path.exists()
        self.rows: list[dict[str, tuple[str, str]]] = []
        if not self.exists:
            return
        root = ET.parse(path).getroot()
        node = root.find("node")
        if node is None:
            return
        schema = node.find("schema")
        if schema is None:
            return
        columns = [
            column.findtext("mnemonic", default="")
            for column in schema.findall("col")
        ]
        identifiers: dict[str, tuple[str, str]] = {}
        for row in node.findall("row"):
            values: list[tuple[str, str]] = []
            for element in list(row):
                reference = element.get("ref")
                if reference is not None and reference in identifiers:
                    resolved = identifiers[reference]
                else:
                    raw = (element.text or "").strip()
                    display = element.get("fmt", raw)
                    resolved = (raw, display)
                    identifier = element.get("id")
                    if identifier is not None:
                        identifiers[identifier] = resolved
                values.append(resolved)
            self.rows.append(dict(zip(columns, values)))


def duration_seconds(row: dict[str, tuple[str, str]]) -> float:
    raw = number(row.get("duration", ("0", ""))[0]) or 0
    return raw * 1e-9


def read_frequencies(path: Path) -> dict[int, int]:
    frequencies: dict[int, int] = {}
    if not path.exists():
        return frequencies
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.startswith("PERF_STATE table=0 "):
            continue
        fields = dict(
            field.split("=", 1)
            for field in line.split()[1:]
            if "=" in field
        )
        frequencies[int(fields["state"])] = int(fields["frequency_hz"])
    return frequencies


def summarize_agx(path: Path) -> Iterable[str]:
    samples = []
    errors = 0
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        sample = json.loads(line)
        if "error" in sample:
            errors += 1
        else:
            samples.append(sample)
    yield f"AGX_SAMPLE_COUNTS valid={len(samples)} errors={errors}"
    for phase in sorted({sample.get("phase", "unknown") for sample in samples}):
        phase_samples = [
            sample for sample in samples if sample.get("phase", "unknown") == phase
        ]
        values = [
            float(sample["device_utilization_percent"])
            for sample in phase_samples
            if sample.get("device_utilization_percent") is not None
        ]
        if not values:
            yield (
                f"AGX_UTILIZATION phase={phase}"
                f" samples={len(phase_samples)} values=0"
            )
            continue
        yield (
            f"AGX_UTILIZATION phase={phase}"
            f" samples={len(values)}"
            f" median_percent={fmt(statistics.median(values))}"
            f" p10_percent={fmt(percentile(values, 0.10))}"
            f" p90_percent={fmt(percentile(values, 0.90))}"
            f" min_percent={fmt(min(values))}"
            f" max_percent={fmt(max(values))}"
            f" samples_ge_90={sum(value >= 90 for value in values)}"
            f" samples_ge_99={sum(value >= 99 for value in values)}"
        )
        active_values = [value for value in values if value > 0]
        if active_values:
            yield (
                f"AGX_ACTIVE_UTILIZATION phase={phase}"
                f" samples={len(active_values)}"
                f" median_percent={fmt(statistics.median(active_values))}"
                f" p10_percent={fmt(percentile(active_values, 0.10))}"
                f" p90_percent={fmt(percentile(active_values, 0.90))}"
                f" min_percent={fmt(min(active_values))}"
                f" max_percent={fmt(max(active_values))}"
            )


def field_safe(value: str) -> str:
    return "_".join(value.split())


def summarize_device_states(table: TraceTable) -> Iterable[str]:
    if not table.rows:
        yield "TRACE_DEVICE_STATE status=unavailable rows=0"
        return
    durations: collections.Counter[tuple[int, int]] = collections.Counter()
    for row in table.rows:
        state_value = number(row.get("state", ("", ""))[0])
        desired_value = number(row.get("desired-state", ("", ""))[0])
        if state_value is None or desired_value is None:
            continue
        durations[(int(state_value), int(desired_value))] += duration_seconds(row)
    total = sum(durations.values())
    for (state, desired), seconds in sorted(durations.items()):
        yield (
            f"TRACE_DEVICE_STATE raw_state={state}"
            f" raw_desired_state={desired}"
            f" duration_s={fmt(seconds, 6)}"
            f" fraction={fmt(seconds / total if total else math.nan, 6)}"
            " semantics=opaque_performance_level"
        )
    yield (
        f"TRACE_DEVICE_STATE_SUMMARY rows={len(table.rows)}"
        f" duration_s={fmt(total, 6)}"
        " frequency_mapping=not_valid"
    )


def summarize_performance_levels(table: TraceTable) -> Iterable[str]:
    if not table.rows:
        yield "TRACE_PERFORMANCE_LEVEL status=unavailable rows=0"
        return
    durations: collections.Counter[str] = collections.Counter()
    reasons: collections.Counter[str] = collections.Counter()
    induced_seconds = 0.0
    for row in table.rows:
        seconds = duration_seconds(row)
        state = row.get(
            "gpu-performance-state", ("unknown", "unknown")
        )[1]
        durations[state] += seconds
        if number(row.get("is-induced", ("0", ""))[0]):
            induced_seconds += seconds
        reason = row.get("narrative", ("unknown", "unknown"))[1]
        reasons[reason] += seconds
    total = sum(durations.values())
    for state, seconds in sorted(durations.items()):
        yield (
            f"TRACE_PERFORMANCE_LEVEL state={field_safe(state)}"
            f" duration_s={fmt(seconds, 6)}"
            f" fraction={fmt(seconds / total if total else math.nan, 6)}"
        )
    for reason, seconds in sorted(reasons.items()):
        yield (
            f"TRACE_PERFORMANCE_REASON reason={field_safe(reason)}"
            f" duration_s={fmt(seconds, 6)}"
            f" fraction={fmt(seconds / total if total else math.nan, 6)}"
        )
    yield (
        f"TRACE_PERFORMANCE_LEVEL_SUMMARY rows={len(table.rows)}"
        f" duration_s={fmt(total, 6)}"
        f" induced_s={fmt(induced_seconds, 6)}"
    )


def summarize_counter_info(table: TraceTable) -> Iterable[str]:
    if not table.rows:
        yield "TRACE_COUNTER_INFO status=unavailable rows=0"
        return
    yield f"TRACE_COUNTER_INFO status=available rows={len(table.rows)}"
    for row in table.rows:
        name = row.get("name", ("unknown", "unknown"))[1]
        counter_type = row.get("type", ("unknown", "unknown"))[1]
        maximum = row.get("max-value", ("unknown", "unknown"))[0]
        description = row.get("description", ("unknown", "unknown"))[1]
        yield (
            f"TRACE_COUNTER name={field_safe(name)}"
            f" type={field_safe(counter_type)}"
            f" max_value={maximum}"
            f" description={field_safe(description)}"
        )


def summarize_consistent_state(table: TraceTable) -> Iterable[str]:
    if not table.rows:
        yield "TRACE_CONSISTENT_STATE status=unavailable rows=0"
        return
    for row in table.rows:
        available = bool(
            number(row.get("consistent-state-available", ("0", ""))[0])
        )
        enabled = bool(
            number(row.get("consistent-state-enabled", ("0", ""))[0])
        )
        sustained = bool(
            number(row.get("consistent-state-sustained", ("0", ""))[0])
        )
        yield (
            "TRACE_CONSISTENT_STATE"
            f" available={'yes' if available else 'no'}"
            f" enabled={'yes' if enabled else 'no'}"
            f" sustained={'yes' if sustained else 'no'}"
        )


def summarize_thermal(table: TraceTable) -> Iterable[str]:
    if not table.rows:
        yield "TRACE_THERMAL status=unavailable rows=0"
        return
    durations: collections.Counter[str] = collections.Counter()
    for row in table.rows:
        state = row.get("thermal-state", ("unknown", "unknown"))[1]
        durations[state] += duration_seconds(row)
    total = sum(durations.values())
    for state, seconds in sorted(durations.items()):
        yield (
            f"TRACE_THERMAL state={state.replace(' ', '_')}"
            f" duration_s={fmt(seconds, 6)}"
            f" fraction={fmt(seconds / total if total else math.nan, 6)}"
        )


def summarize_gpu_state(table: TraceTable) -> Iterable[str]:
    if not table.rows:
        yield "TRACE_GPU_STATE status=unavailable rows=0"
        return
    durations: collections.Counter[str] = collections.Counter()
    for row in table.rows:
        state = row.get("state", ("unknown", "unknown"))[1]
        durations[state] += duration_seconds(row)
    total = sum(durations.values())
    for state, seconds in sorted(durations.items()):
        yield (
            f"TRACE_GPU_STATE state={state.replace(' ', '_')}"
            f" duration_s={fmt(seconds, 6)}"
            f" fraction={fmt(seconds / total if total else math.nan, 6)}"
        )


def summarize_gpu_intervals(table: TraceTable) -> Iterable[str]:
    groups: dict[str, list[tuple[float, float, float, str]]] = {}
    for row in table.rows:
        start_ns = number(row.get("start", ("", ""))[0])
        duration_ns = number(row.get("duration", ("", ""))[0])
        start_latency_ns = number(row.get("start-latency", ("", ""))[0])
        depth = number(row.get("event-depth", ("0", ""))[0]) or 0
        state = row.get("state", ("", ""))[1]
        if (
            start_ns is None
            or duration_ns is None
            or duration_ns <= 0
            or depth != 0
            or state not in {"", "Active"}
        ):
            continue
        process = row.get("process", ("unknown", "unknown"))[1]
        channel = row.get("channel-name", ("unknown", "unknown"))[1]
        groups.setdefault(process, []).append(
            (
                start_ns * 1e-9,
                (start_ns + duration_ns) * 1e-9,
                (start_latency_ns or 0) * 1e-9,
                channel,
            )
        )
    if not groups:
        yield "TRACE_GPU_INTERVALS status=unavailable rows=0"
        return

    for process, intervals in sorted(groups.items()):
        intervals.sort()
        merged: list[list[float]] = []
        for start, end, _, _ in intervals:
            if merged and start <= merged[-1][1]:
                merged[-1][1] = max(merged[-1][1], end)
            else:
                merged.append([start, end])
        busy_seconds = sum(end - start for start, end in merged)
        span_seconds = merged[-1][1] - merged[0][0]
        gaps = [
            merged[index][0] - merged[index - 1][1]
            for index in range(1, len(merged))
        ]
        start_latencies = sorted(interval[2] for interval in intervals)
        channel_counts = collections.Counter(interval[3] for interval in intervals)
        channel_field = ",".join(
            f"{field_safe(channel)}:{count}"
            for channel, count in sorted(channel_counts.items())
        )
        yield (
            f"TRACE_GPU_INTERVALS process={field_safe(process)}"
            f" rows={len(intervals)}"
            f" channels={channel_field}"
            f" span_s={fmt(span_seconds, 6)}"
            f" busy_s={fmt(busy_seconds, 6)}"
            f" duty_fraction="
            f"{fmt(busy_seconds / span_seconds if span_seconds else math.nan, 6)}"
            f" idle_gap_s={fmt(max(0, span_seconds - busy_seconds), 6)}"
            f" gap_count={len(gaps)}"
            f" gap_median_us="
            f"{fmt(statistics.median(gaps) * 1e6 if gaps else 0, 3)}"
            f" gap_p90_us="
            f"{fmt(percentile(gaps, 0.90) * 1e6 if gaps else 0, 3)}"
            f" gap_max_us={fmt(max(gaps) * 1e6 if gaps else 0, 3)}"
            f" start_latency_median_us="
            f"{fmt(statistics.median(start_latencies) * 1e6, 3)}"
            f" start_latency_p90_us="
            f"{fmt(percentile(start_latencies, 0.90) * 1e6, 3)}"
        )


def summarize_counts(directory: Path) -> Iterable[str]:
    schemas = [
        "graphics-compiler-spill-events",
        "metal-kernel-resource-allocations",
        "metal-gpu-intervals",
        "metal-application-command-buffer-submissions",
    ]
    for schema in schemas:
        table = TraceTable(directory / f"{schema}.xml")
        status = "exported" if table.exists else "not_exported"
        yield (
            f"TRACE_TABLE schema={schema}"
            f" status={status}"
            f" rows={len(table.rows)}"
        )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--agx-jsonl", type=Path, required=True)
    parser.add_argument("--trace-directory", type=Path, required=True)
    parser.add_argument("--perf-inventory", type=Path, required=True)
    return parser.parse_args()


def main() -> None:
    arguments = parse_args()
    frequencies = read_frequencies(arguments.perf_inventory)
    for line in summarize_agx(arguments.agx_jsonl):
        print(line)
    maximum_frequency = max(frequencies.values(), default=0)
    print(
        "GPU_CLOCK_OBSERVABILITY"
        " live_frequency_hz=unavailable"
        f" static_table_max_frequency_hz={maximum_frequency or 'unavailable'}"
        " qualitative_performance_level=available_via_xctrace"
        " note=trace_level_enums_are_not_perf_state_table_indices"
    )
    device_state_table = TraceTable(
        arguments.trace_directory / "gpu-performance-device-state-intervals.xml"
    )
    for line in summarize_device_states(device_state_table):
        print(line)
    performance_level_table = TraceTable(
        arguments.trace_directory / "gpu-performance-state-intervals.xml"
    )
    for line in summarize_performance_levels(performance_level_table):
        print(line)
    thermal_table = TraceTable(
        arguments.trace_directory / "device-thermal-state-intervals.xml"
    )
    for line in summarize_thermal(thermal_table):
        print(line)
    gpu_state_table = TraceTable(
        arguments.trace_directory / "metal-gpu-state-intervals.xml"
    )
    for line in summarize_gpu_state(gpu_state_table):
        print(line)
    gpu_interval_table = TraceTable(
        arguments.trace_directory / "metal-gpu-intervals.xml"
    )
    for line in summarize_gpu_intervals(gpu_interval_table):
        print(line)
    counter_info_table = TraceTable(
        arguments.trace_directory / "gpu-counter-info.xml"
    )
    for line in summarize_counter_info(counter_info_table):
        print(line)
    consistent_state_table = TraceTable(
        arguments.trace_directory / "gpu-performance-state-info.xml"
    )
    for line in summarize_consistent_state(consistent_state_table):
        print(line)
    for line in summarize_counts(arguments.trace_directory):
        print(line)


if __name__ == "__main__":
    main()
