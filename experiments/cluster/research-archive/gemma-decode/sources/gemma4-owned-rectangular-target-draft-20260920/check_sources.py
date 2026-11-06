#!/usr/bin/env python3
"""Read only: exact small overlay/context pins, absence and patch inversion."""
import argparse
import difflib
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent


def matches(path, expected):
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"not a regular source file: {path}")
    data = path.read_bytes()
    if len(data) != expected["bytes"] or hashlib.sha256(data).hexdigest() != expected["sha256"]:
        raise ValueError(f"source bytes changed: {path}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", type=Path)
    args = parser.parse_args()
    manifest = json.loads((ROOT / "manifest.json").read_text())
    for row in manifest["members"]:
        matches(ROOT / row["path"], row)
    integration = json.loads((ROOT / "integration.json").read_text())
    context = json.loads((ROOT / "source-context.json").read_text())
    base = args.base or Path(integration["base"])
    patch = []
    paths = []
    for row in integration["overlays"]:
        relative = row["path"]
        paths.append(relative)
        candidate = ROOT / row["sourcePath"]
        matches(candidate, row["after"])
        original = ROOT / "originals" / relative
        if row["before"] is None:
            if original.exists() or (base / relative).exists() or (base / relative).is_symlink():
                raise ValueError(f"new path is not absent: {relative}")
            before = []
        else:
            matches(original, row["before"])
            matches(base / relative, row["before"])
            before = original.read_text().splitlines(True)
        patch.extend(difflib.unified_diff(before, candidate.read_text().splitlines(True),
                     fromfile="a/" + relative if row["before"] else "/dev/null", tofile="b/" + relative))
    if len(paths) != 14 or len(paths) != len(set(paths)):
        raise ValueError("overlay coverage differs")
    if "".join(patch) != (ROOT / "runtime.patch").read_text():
        raise ValueError("patch no longer reconstructs the exact overlay")
    for row in context["members"]:
        matches(base / row["path"], row)
    print(json.dumps({"passed": True, "manifestMembers": len(manifest["members"]),
                      "overlays": len(paths), "contextPins": len(context["members"]),
                      "execution": "source-only; no compiler, fixture, GPU, model or remote"}, sort_keys=True))


if __name__ == "__main__":
    main()
