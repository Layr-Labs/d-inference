#!/usr/bin/env python3
"""Read public IORegistry GPU metadata and utilization without privileges."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import plistlib
import struct
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Iterator


def ioreg_plist(*arguments: str) -> Any:
    output = subprocess.check_output(
        ["/usr/sbin/ioreg", *arguments, "-a"],
        stderr=subprocess.STDOUT,
    )
    return plistlib.loads(output)


def walk_registry(node: dict[str, Any]) -> Iterator[dict[str, Any]]:
    yield node
    for child in node.get("IORegistryEntryChildren", []):
        yield from walk_registry(child)


def uint32(data: bytes) -> int:
    if len(data) != 4:
        raise ValueError(f"expected a 4-byte integer, got {len(data)} bytes")
    return struct.unpack("<I", data)[0]


def print_inventory() -> None:
    service = ioreg_plist(
        "-r",
        "-c",
        "AGXFamilyAccelerator",
        "-d",
        "1",
    )[0]
    config = service.get("GPUConfigurationVariable", {})
    print(
        "AGX_INVENTORY"
        f" model={service.get('model', 'unknown')}"
        f" gpu_gen={config.get('gpu_gen', 'unknown')}"
        f" gpu_variant={config.get('gpu_var', 'unknown')}"
        f" cores={config.get('num_cores', service.get('gpu-core-count', 'unknown'))}"
        f" mgpus={config.get('num_mgpus', 'unknown')}"
        f" trace_code={service.get('AGXTraceCodeVersion', 'unknown')}"
    )

    tree = ioreg_plist("-p", "IODeviceTree", "-l")
    sgx = next(
        node
        for node in walk_registry(tree)
        if node.get("IORegistryEntryName") == "sgx"
    )
    state_count = uint32(sgx["perf-state-count"])
    table_count = uint32(sgx["perf-state-table-count"])
    base_state = uint32(sgx["gpu-perf-base-pstate"])
    advertised_states = uint32(sgx["gpu-num-perf-states"])
    raw = sgx["perf-states"]
    values = struct.unpack(f"<{len(raw) // 4}I", raw)
    expected_values = state_count * table_count * 2
    if len(values) != expected_values:
        raise ValueError(
            "unexpected perf-states size:"
            f" got {len(values)} uint32 values, expected {expected_values}"
        )
    print(
        "PERF_STATE_TABLES"
        f" tables={table_count}"
        f" states_per_table={state_count}"
        f" advertised_nonzero_states={advertised_states}"
        f" base_state={base_state}"
    )
    maximum_frequency = 0
    for table in range(table_count):
        offset = table * state_count * 2
        for state in range(state_count):
            frequency_hz = values[offset + state * 2]
            voltage_mv = values[offset + state * 2 + 1]
            maximum_frequency = max(maximum_frequency, frequency_hz)
            print(
                "PERF_STATE"
                f" table={table}"
                f" state={state}"
                f" frequency_hz={frequency_hz}"
                f" voltage_mv={voltage_mv}"
            )
    print(f"PERF_STATE_MAX_FREQUENCY_HZ={maximum_frequency}")
    throttle_legends = [
        legend
        for legend in service.get("IOReportLegend", [])
        if legend.get("IOReportSubGroupName") == "GPU Throttler Counters"
    ]
    for legend in throttle_legends:
        for channel in legend.get("IOReportChannels", []):
            name = channel[2] if len(channel) > 2 else "unnamed"
            print(
                "THROTTLE_CHANNEL_DEFINITION"
                f" name={str(name).strip().replace(' ', '_')}"
                " sampled_value=unavailable-via-ioreg"
            )


def capture_statistics(phase: str, elapsed_seconds: float) -> dict[str, Any]:
    service = ioreg_plist(
        "-r",
        "-c",
        "AGXFamilyAccelerator",
        "-d",
        "1",
    )[0]
    statistics = service.get("PerformanceStatistics", {})
    return {
        "timestamp_utc": dt.datetime.now(dt.timezone.utc)
        .isoformat(timespec="milliseconds")
        .replace("+00:00", "Z"),
        "elapsed_seconds": round(elapsed_seconds, 6),
        "phase": phase,
        "device_utilization_percent": statistics.get("Device Utilization %"),
        "renderer_utilization_percent": statistics.get("Renderer Utilization %"),
        "tiler_utilization_percent": statistics.get("Tiler Utilization %"),
        "allocated_system_memory_bytes": statistics.get("Alloc system memory"),
        "in_use_system_memory_bytes": statistics.get("In use system memory"),
        "in_use_driver_memory_bytes": statistics.get(
            "In use system memory (driver)"
        ),
        "recovery_count": statistics.get("recoveryCount"),
        "last_recovery_time": statistics.get("lastRecoveryTime"),
        "last_submission_pid": service.get("AGCInfo", {}).get("fLastSubmissionPID"),
    }


def current_phase(path: Path) -> str:
    try:
        value = path.read_text(encoding="utf-8").strip()
    except OSError:
        return "unknown"
    return value or "unknown"


def sample_once(phase: str) -> None:
    print(json.dumps(capture_statistics(phase, 0), sort_keys=True))


def sample_loop(phase_file: Path, stop_file: Path, interval_seconds: float) -> None:
    if interval_seconds <= 0:
        raise ValueError("sample interval must be positive")
    start = time.monotonic()
    next_sample = start
    while not stop_file.exists():
        now = time.monotonic()
        try:
            sample = capture_statistics(
                current_phase(phase_file),
                now - start,
            )
        except Exception as error:  # Preserve a failed sample in the artifact.
            sample = {
                "timestamp_utc": dt.datetime.now(dt.timezone.utc)
                .isoformat(timespec="milliseconds")
                .replace("+00:00", "Z"),
                "elapsed_seconds": round(now - start, 6),
                "phase": current_phase(phase_file),
                "error": str(error),
            }
        print(json.dumps(sample, sort_keys=True), flush=True)
        next_sample += interval_seconds
        time.sleep(max(0, next_sample - time.monotonic()))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("inventory")

    once = subparsers.add_parser("once")
    once.add_argument("--phase", required=True)

    loop = subparsers.add_parser("loop")
    loop.add_argument("--phase-file", type=Path, required=True)
    loop.add_argument("--stop-file", type=Path, required=True)
    loop.add_argument("--interval", type=float, default=1.0)
    return parser.parse_args()


def main() -> int:
    arguments = parse_args()
    if arguments.command == "inventory":
        print_inventory()
    elif arguments.command == "once":
        sample_once(arguments.phase)
    else:
        sample_loop(
            arguments.phase_file,
            arguments.stop_file,
            arguments.interval,
        )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"fatal: {error}", file=sys.stderr)
        raise SystemExit(1)
