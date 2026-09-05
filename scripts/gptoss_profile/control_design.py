"""Reviewable two-arm experiment designs and deterministic ABBA scheduling."""

import json
from pathlib import Path

from .config import Cell, environment


def load_design(path):
    path = Path(path).resolve()
    data = json.loads(path.read_text())
    allowed = {"schemaVersion", "modelID", "modelDirectory", "decodeTokens", "kvBackend", "config", "arms", "description", "requiredACPowerMode"}
    if set(data) - allowed or data.get("schemaVersion") != 1:
        raise ValueError("Design must use schemaVersion 1 and only documented keys")
    if not isinstance(data.get("modelID"), str) or not data["modelID"]:
        raise ValueError("Design requires modelID")

    def resolve(value):
        if not isinstance(value, str) or not value:
            raise ValueError("Artifact/model paths must be nonempty strings")
        value = Path(value).expanduser()
        return str((path.parent / value).resolve()) if not value.is_absolute() else str(value.resolve())

    data["modelDirectory"] = resolve(data.get("modelDirectory"))
    data["decodeTokens"] = data.get("decodeTokens", 256)
    if type(data["decodeTokens"]) is not int or data["decodeTokens"] < 32:
        raise ValueError("decodeTokens must be an integer >=32")
    data["kvBackend"] = data.get("kvBackend", "contiguous")
    data["requiredACPowerMode"] = data.get("requiredACPowerMode", 2)
    if data["requiredACPowerMode"] != 2:
        raise ValueError("ABBA controls require requiredACPowerMode 2")
    if data["kvBackend"] not in {"contiguous", "paged"}:
        raise ValueError("kvBackend must explicitly name contiguous or paged")
    if data.get("config"):
        data["config"] = resolve(data["config"])
    arms = data.get("arms")
    if not isinstance(arms, list) or len(arms) != 2 or [arm.get("name") for arm in arms] != ["A", "B"]:
        raise ValueError("Design requires exactly two ordered arms named A and B")
    for arm in arms:
        if set(arm) - {"name", "label", "binary", "metallib", "metallibs", "buildRecord", "cell", "environment"}:
            raise ValueError(f"Arm {arm['name']} has unknown keys")
        arm["label"] = arm.get("label", arm["name"])
        if not isinstance(arm["label"], str) or not arm["label"]:
            raise ValueError("Arm labels must be nonempty strings")
        arm["binary"] = resolve(arm.get("binary"))
        arm["buildRecord"] = resolve(arm.get("buildRecord"))
        libraries = arm.pop("metallib", None)
        if libraries is not None and "metallibs" in arm:
            raise ValueError("Use metallib or metallibs, not both")
        libraries = [libraries] if libraries is not None else arm.get("metallibs")
        if not isinstance(libraries, list) or not libraries:
            raise ValueError("Every arm needs one or more explicit metallibs")
        arm["metallibs"] = [resolve(value) for value in libraries]
        shape = arm.get("cell", {})
        phase = shape.get("phase", "decode")
        if set(shape) - {"phase", "context", "batch"} or phase not in {"decode", "prefill"}:
            raise ValueError("ABBA controls support decode or prefill cells")
        batch = shape.get("batch", 1 if phase == "prefill" else None)
        if (type(shape.get("context")) is not int or shape["context"] < (2 if phase == "prefill" else 1)
                or type(batch) is not int or batch not in ({1} if phase == "prefill" else {1, 2, 4, 8})):
            raise ValueError("Prefill requires context>=2 and batch1; decode requires positive context and batch1/2/4/8")
        arm["cell"] = Cell(phase, shape["context"], batch).record()
        overrides = arm.get("environment", {})
        if not isinstance(overrides, dict) or any(not isinstance(k, str) or not isinstance(v, str) for k, v in overrides.items()):
            raise ValueError("Arm environment must map string keys to string values")
        _, explicit = environment({}, [f"{key}={value}" for key, value in overrides.items()])
        instrumentation = [key for key, value in explicit.items()
                           if any(word in key for word in ("PROFILE", "TRACE", "TIMING", "CAPTURE", "DEBUG"))
                           and value.lower() not in {"0", "false", "no", "off", ""}]
        if instrumentation:
            raise ValueError(f"ABBA timing controls require instrumentation disabled: {instrumentation}")
        arm["environment"] = explicit
    if arms[0]["cell"]["context"] != arms[1]["cell"]["context"]:
        raise ValueError("ABBA arms must share context length for matched input/output comparison")
    if arms[0]["cell"]["phase"] != arms[1]["cell"]["phase"]:
        raise ValueError("ABBA arms must share phase")
    return data


def schedule(cycles):
    if type(cycles) is not int or cycles < 1:
        raise ValueError("cycles must be a positive integer")
    return [{"name": f"cycle-{cycle:02d}-{position}-{arm}", "cycle": cycle, "position": position, "arm": arm}
            for cycle in range(1, cycles + 1) for position, arm in enumerate("ABBA", 1)]
