"""Parse and enforce the observed macOS power source and AC power mode."""

import re


def parse_power(custom, battery):
    modes, section = {}, None
    for line in custom.splitlines():
        if line.strip() in {"AC Power:", "Battery Power:"}:
            section = line.strip().removesuffix(":")
        elif section:
            match = re.fullmatch(r"\s*(powermode|lowpowermode)\s+(\d+)\s*", line)
            if match:
                modes.setdefault(section, {})[match[1]] = int(match[2])
    source = re.search(r"Now drawing from '([^']+)'", battery)
    return {"source": source.group(1) if source else None,
            "acPowerMode": modes.get("AC Power", {}).get("powermode"),
            "batteryPowerMode": modes.get("Battery Power", {}).get("powermode"),
            "lowPowerModeBySource": {key: value["lowpowermode"] for key, value in modes.items()
                                     if "lowpowermode" in value}}


def power_failure(snapshot, required):
    if required is None:
        return None
    power = snapshot.get("power", {})
    if power.get("source") != "AC Power":
        return f"Expected AC Power, observed {power.get('source')!r}"
    if power.get("acPowerMode") != required:
        return f"Expected AC powermode {required}, observed {power.get('acPowerMode')!r}"
    return None
