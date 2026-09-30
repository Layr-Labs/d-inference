"""Read actual macOS power policy; low-power=false alone cannot exclude High Power."""
import re
import subprocess


def parse_posture(settings, battery):
    source = "ac" if "Now drawing from 'AC Power'" in battery else "battery" if "Now drawing from 'Battery Power'" in battery else "unknown"
    section, modes = None, {}
    for line in settings.splitlines():
        if line.strip() in ("AC Power:", "Battery Power:"):
            section = "ac" if line.strip() == "AC Power:" else "battery"
        match = re.fullmatch(r"\s*powermode\s+(\d+)\s*", line)
        if match and section:
            modes[section] = int(match[1])
    raw = modes.get(source)
    return {"source": source, "mode": {0: "automatic", 1: "low", 2: "high"}.get(raw, "unknown"),
            "raw_mode": raw}


def read_posture():
    try:
        settings = subprocess.check_output(["/usr/bin/pmset", "-g", "custom"], text=True, timeout=5)
        battery = subprocess.check_output(["/usr/bin/pmset", "-g", "batt"], text=True, timeout=5)
        return parse_posture(settings, battery)
    except (OSError, subprocess.SubprocessError):
        return {"source": "unknown", "mode": "unknown", "raw_mode": None}
