"""Toolchain, hardware, power, thermal, and process posture capture."""

from __future__ import annotations

import re
from pathlib import Path
from typing import Any

from provenance_common import ProvenanceError, run_command


def _capture_gpu_summary() -> dict[str, Any]:
    result = run_command(["system_profiler", "SPDisplaysDataType"])
    allowed_fields = {
        "Chipset Model": "chipset_model",
        "Metal Support": "metal_support",
        "Total Number of Cores": "core_count",
        "Vendor": "vendor",
    }
    adapters: list[dict[str, str]] = []
    current: dict[str, str] = {}
    if result["exit_code"] == 0:
        for line in result["stdout"].splitlines():
            key, separator, value = line.strip().partition(":")
            if not separator or key not in allowed_fields:
                continue
            if key == "Chipset Model" and current:
                adapters.append(current)
                current = {}
            current[allowed_fields[key]] = value.strip()
        if current:
            adapters.append(current)
    return {
        "adapters": adapters,
        "argv": result["argv"],
        "available": result["available"],
        "exit_code": result["exit_code"],
        "stderr": result["stderr"],
    }


def capture_host() -> dict[str, Any]:
    return {
        "hardware": {
            "gpu": _capture_gpu_summary(),
            "machine_model": run_command(["sysctl", "-n", "hw.model"]),
            "memory_bytes": run_command(["sysctl", "-n", "hw.memsize"]),
        },
        "os": {
            "sw_vers": run_command(["sw_vers"]),
            "uname": run_command(["uname", "-srvmp"]),
        },
        "toolchain": {
            "metal": run_command(["xcrun", "-sdk", "macosx", "metal", "--version"]),
            "metallib": run_command(
                ["xcrun", "-sdk", "macosx", "metallib", "--version"]
            ),
            "swift": run_command(["swift", "--version"]),
            "xcode": run_command(["xcodebuild", "-version"]),
        },
    }


def capture_power_and_thermal() -> dict[str, Any]:
    battery = run_command(["pmset", "-g", "batt"])
    custom = run_command(["pmset", "-g", "custom"])
    thermal = run_command(["pmset", "-g", "therm"])

    mode: int | None = None
    in_ac = False
    for line in custom["stdout"].splitlines():
        if line.startswith("AC Power:"):
            in_ac = True
            continue
        if line and not line[0].isspace() and line.endswith("Power:"):
            in_ac = False
        if in_ac:
            match = re.match(r"\s*powermode\s+(\d+)\s*$", line)
            if match:
                mode = int(match.group(1))
                break

    return {
        "ac_power": (
            "AC Power" in battery["stdout"] if battery["exit_code"] == 0 else None
        ),
        "battery": battery,
        "power_mode_ac": mode,
        "settings": custom,
        "thermal": {
            "cpu_level": run_command(
                ["sysctl", "-n", "machdep.xcpm.cpu_thermal_level"]
            ),
            "gpu_level": run_command(
                ["sysctl", "-n", "machdep.xcpm.gpu_thermal_level"]
            ),
            "io_level": run_command(
                ["sysctl", "-n", "machdep.xcpm.io_thermal_level"]
            ),
            "pmset": thermal,
        },
    }


def capture_competing_processes(limit: int = 30) -> dict[str, Any]:
    if limit < 1:
        raise ProvenanceError("process limit must be positive")
    result = run_command(
        ["ps", "-axo", "pid=,ppid=,pcpu=,pmem=,etime=,comm="]
    )
    entries: list[dict[str, Any]] = []
    if result["exit_code"] == 0:
        for line in result["stdout"].splitlines():
            fields = line.strip().split(None, 5)
            if len(fields) != 6:
                continue
            try:
                pid = int(fields[0])
                parent_pid = int(fields[1])
                cpu = float(fields[2])
                memory = float(fields[3])
            except ValueError:
                continue
            entries.append(
                {
                    "cpu_percent": cpu,
                    "elapsed": fields[4],
                    "executable": Path(fields[5]).name,
                    "memory_percent": memory,
                    "parent_pid": parent_pid,
                    "pid": pid,
                }
            )
        entries.sort(key=lambda item: (-item["cpu_percent"], item["pid"]))
        entries = entries[:limit]
    return {
        "capture": {
            "argv": result["argv"],
            "available": result["available"],
            "exit_code": result["exit_code"],
            "stderr": result["stderr"],
        },
        "entries": entries,
        "includes_command_arguments": False,
        "limit": limit,
    }
