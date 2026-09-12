"""Content pins and privacy-conscious read-only host snapshots."""

import hashlib
import json
import os
import platform
import re
import subprocess
from datetime import datetime, timezone
from pathlib import Path

from .power import parse_power


def now():
    return datetime.now(timezone.utc).isoformat()


def digest(path):
    value = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(4 * 1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def fingerprint(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def write_json(path, value):
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    temporary.replace(path)


def capture(command, cwd=None):
    try:
        result = subprocess.run(command, cwd=cwd, capture_output=True, text=True, timeout=15)
        return {"returncode": result.returncode, "stdout": result.stdout.strip(),
                "stderr": result.stderr.strip()}
    except (OSError, subprocess.TimeoutExpired) as error:
        return {"unavailable": type(error).__name__}


def source_pin(repo):
    # Diff contents may contain private configuration; only record its hash.
    tracked = subprocess.run(["git", "diff", "--binary", "HEAD"], cwd=repo,
                             check=True, capture_output=True).stdout
    submodules = capture(["git", "submodule", "status", "--recursive"], repo)
    modules = []
    for line in submodules.get("stdout", "").splitlines():
        parts = line.split()
        if len(parts) >= 2:
            path = Path(repo) / parts[1]
            if path.is_dir():
                modules.append({"path": parts[1], **checkout_edits(path)})
    return {"head": capture(["git", "rev-parse", "HEAD"], repo),
            "branch": capture(["git", "branch", "--show-current"], repo),
            "trackedDiffSHA256": hashlib.sha256(tracked).hexdigest(),
            "untrackedSource": untracked_source(repo),
            "submodules": submodules, "submoduleEdits": modules,
            "note": "Source observed at run start; this alone does not attest how a supplied binary was built."}


SOURCE_SUFFIXES = {".swift", ".py", ".sh", ".metal", ".cpp", ".cc", ".c", ".h", ".hpp", ".mm", ".m", ".json", ".toml", ".cmake"}


def untracked_source(repo):
    result = subprocess.run(["git", "ls-files", "--others", "--exclude-standard", "-z"],
                            cwd=repo, check=True, capture_output=True)
    entries = []
    for raw in result.stdout.split(b"\0"):
        if not raw:
            continue
        relative = Path(os.fsdecode(raw))
        if (any(part in {"artifacts", "build", ".build", "node_modules", "__pycache__", ".venv"}
                for part in relative.parts) or relative.suffix not in SOURCE_SUFFIXES):
            continue
        path = Path(repo) / relative
        if path.is_file():
            entries.append({"path": str(relative), "sha256": digest(path)})
    return sorted(entries, key=lambda entry: entry["path"])


def checkout_edits(repo):
    tracked = subprocess.run(["git", "diff", "--binary", "HEAD"], cwd=repo,
                             check=True, capture_output=True).stdout
    return {"trackedDiffSHA256": hashlib.sha256(tracked).hexdigest(),
            "untrackedSource": untracked_source(repo)}


def file_pin(path):
    requested = Path(path).absolute()
    path = requested.resolve()
    return {"path": str(path), "requestedPath": str(requested),
            "bytes": path.stat().st_size, "sha256": digest(path)}


def model_pin(directory):
    directory = Path(directory).resolve()
    files = [{"name": str(p.relative_to(directory)), "bytes": p.stat().st_size,
              "sha256": digest(p)} for p in sorted(directory.rglob("*"))
             if p.is_file() and not any(part.startswith(".") for part in p.relative_to(directory).parts)]
    if not files or not any(p["name"].endswith(".safetensors") for p in files):
        raise ValueError("--model-dir must contain the resolved model snapshot and safetensors weights")
    return {"path": str(directory), "files": files, "inventorySHA256": fingerprint(files)}


def assert_artifacts_unchanged(pins):
    """Recheck content, including snapshot additions/removals, outside timing."""
    for artifact in [pins["binary"], *pins["metallibs"], pins.get("config"), pins.get("buildRecord")]:
        if artifact is not None and file_pin(artifact["requestedPath"]) != artifact:
            raise ValueError(f"Pinned artifact changed: {artifact['path']}")
    if model_pin(pins["model"]["path"]) != pins["model"]:
        raise ValueError("Pinned model snapshot changed during matrix")


def host_snapshot():
    # No serial number, hostname, username, network state, or process arguments.
    result = {"capturedAt": now(), "system": platform.system(), "osRelease": platform.release(),
              "architecture": platform.machine(), "cpuCount": os.cpu_count(), "loadAverage": os.getloadavg()}
    if platform.system() == "Darwin":
        result.update({"osVersion": capture(["sw_vers", "-productVersion"]),
                       "hardware": capture(["sysctl", "hw.memsize", "hw.physicalcpu", "hw.logicalcpu", "machdep.cpu.brand_string"]),
                       "virtualMemory": capture(["vm_stat"]),
                       "swap": capture(["sysctl", "vm.swapusage"]),
                       "thermal": capture(["pmset", "-g", "therm"])})
        thermal = capture(["osascript", "-l", "JavaScript", "-e",
                           'ObjC.import("Foundation"); Number($.NSProcessInfo.processInfo.thermalState)'])
        names = {0: "nominal", 1: "fair", 2: "serious", 3: "critical"}
        raw_thermal = thermal.get("stdout", "")
        value = int(raw_thermal) if thermal.get("returncode") == 0 and raw_thermal in {"0", "1", "2", "3"} else None
        result["foundationThermalState"] = {"value": value, "name": names.get(value, "unavailable"), "probe": thermal}
        custom = capture(["pmset", "-g", "custom"])
        battery = capture(["pmset", "-g", "batt"])
        if "stdout" in battery:
            battery["stdout"] = re.sub(r"\s*\(id=[^)]*\)", "", battery["stdout"])
        result["powerCustom"] = custom
        result["powerBattery"] = battery
        result["power"] = parse_power(custom.get("stdout", ""), battery.get("stdout", ""))
        process_cpu = capture(["ps", "-A", "-o", "pid=,stat=,pcpu=,pmem=,comm="])
        if "stdout" in process_cpu:
            lines = [line.split(maxsplit=4) for line in process_cpu["stdout"].splitlines()]
            process_cpu["stdout"] = "\n".join(" ".join(line[:4] + [Path(line[4]).name])
                                              for line in lines if len(line) == 5)
        result["processCPU"] = process_cpu
    return result
