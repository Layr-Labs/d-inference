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
        self.rows: list[dict[str, tuple[str, str]]] = []
        if not path.exists():
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


def summarize_pstates(
    table: TraceTable,
    frequencies: dict[int, int],
) -> Iterable[str]:
    if not table.rows:
        yield "TRACE_PSTATE status=unavailable rows=0"
        return
    durations: collections.Counter[tuple[int, int]] = collections.Counter()
    for row in table.rows:
        state_value = number(row.get("state", ("", ""))[0])
        desired_value = number(row.get("desired-state", ("", ""))[0])
        if state_value is None or desired_value is None:
            continue
        durations[(int(state_value), int(desired_value))] += duration_seconds(row)
    total = sum(durations.values())
    mismatch = sum(
        seconds
        for (state, desired), seconds in durations.items()
        if state < desired
    )
    for (state, desired), seconds in sorted(durations.items()):
        frequency = frequencies.get(state)
        desired_frequency = frequencies.get(desired)
        yield (
            f"TRACE_PSTATE state={state}"
            f" desired_state={desired}"
            f" frequency_hz={frequency if frequency is not None else 'unknown'}"
            " desired_frequency_hz="
            f"{desired_frequency if desired_frequency is not None else 'unknown'}"
            f" duration_s={fmt(seconds, 6)}"
            f" fraction={fmt(seconds / total if total else math.nan, 6)}"
        )
    yield (
        f"TRACE_PSTATE_SUMMARY rows={len(table.rows)}"
        f" duration_s={fmt(total, 6)}"
        f" actual_below_desired_s={fmt(mismatch, 6)}"
        " actual_below_desired_fraction="
        f"{fmt(mismatch / total if total else math.nan, 6)}"
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


def summarize_counts(directory: Path) -> Iterable[str]:
    schemas = [
        "gpu-counter-info",
        "gpu-counter-value",
        "metal-gpu-counter-intervals",
        "graphics-compiler-spill-events",
        "metal-kernel-resource-allocations",
        "metal-gpu-intervals",
        "metal-application-command-buffer-submissions",
    ]
    for schema in schemas:
        table = TraceTable(directory / f"{schema}.xml")
        yield f"TRACE_TABLE schema={schema} rows={len(table.rows)}"


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
    pstate_table = TraceTable(
        arguments.trace_directory / "gpu-performance-device-state-intervals.xml"
    )
    for line in summarize_pstates(pstate_table, frequencies):
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
    for line in summarize_counts(arguments.trace_directory):
        print(line)


if __name__ == "__main__":
    main()
