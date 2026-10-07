#!/usr/bin/env python3
"""Check local/container Go pin parity and the root module's minimum version."""

from pathlib import Path
import re
import sys
import tomllib

ROOT = Path(__file__).resolve().parents[1]


def check(go_mod: str, mise: str, dockerfile: str) -> str:
    requirements = re.findall(r"^go (\d+\.\d+\.\d+)\s*$", go_mod, re.MULTILINE)
    builders = re.findall(
        r"^FROM golang:(\d+\.\d+\.\d+)-alpine@sha256:[0-9a-f]{64} AS builder\s*$",
        dockerfile, re.MULTILINE,
    )
    if len(requirements) != 1 or len(builders) != 1:
        raise ValueError("require one go.mod minimum and one exact digest-pinned Go builder version")
    local = tomllib.loads(mise).get("tools", {}).get("go")
    if local != builders[0]:
        raise ValueError(f"mise Go {local!r} must match Docker builder Go {builders[0]}")
    local_version = tuple(int(part) for part in local.split("."))
    minimum = tuple(int(part) for part in requirements[0].split("."))
    if local_version < minimum:
        raise ValueError(f"Go {local} is older than go.mod minimum {requirements[0]}")
    return f"Go toolchain integrity: local/container={local}, module minimum={requirements[0]}"


if __name__ == "__main__":
    try:
        print(check(
            (ROOT / "go.mod").read_text(),
            (ROOT / "mise.toml").read_text(),
            (ROOT / "coordinator/Dockerfile").read_text(),
        ))
    except (OSError, ValueError) as exc:
        sys.exit(f"Go toolchain check: {exc}")
