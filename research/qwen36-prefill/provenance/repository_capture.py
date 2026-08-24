"""Git and recursive-submodule provenance capture."""

from __future__ import annotations

import re
from pathlib import Path
from typing import Any

from provenance_common import (
    ProvenanceError,
    canonical_json_bytes,
    display_path,
    required_stdout,
    sha256_bytes,
)


_SUBMODULE_RE = re.compile(
    r"^(?P<state>[ +\-U])(?P<sha>[0-9a-fA-F]{40,64})\s+"
    r"(?P<path>\S+)(?:\s+\((?P<description>.*)\))?$"
)


def _status_lines(repo: Path) -> list[str]:
    output = required_stdout(
        ["git", "status", "--porcelain=v1", "--untracked-files=all"], cwd=repo
    )
    return output.splitlines() if output else []


def parse_submodule_status(output: str) -> list[dict[str, Any]]:
    states = {
        " ": "clean",
        "+": "checked_out_sha_differs",
        "-": "uninitialized",
        "U": "conflict",
    }
    records: list[dict[str, Any]] = []
    for line in output.splitlines():
        if not line:
            continue
        match = _SUBMODULE_RE.fullmatch(line)
        if not match:
            raise ProvenanceError(f"cannot parse recursive submodule status: {line!r}")
        state_marker = match.group("state")
        record: dict[str, Any] = {
            "path": match.group("path"),
            "sha": match.group("sha").lower(),
            "state": states[state_marker],
        }
        if match.group("description"):
            record["description"] = match.group("description")
        records.append(record)
    return records


def capture_repository(repo: Path) -> dict[str, Any]:
    repo = repo.expanduser().resolve()
    if not (repo / ".git").exists():
        raise ProvenanceError(f"not a Git worktree: {display_path(repo)}")

    head_sha = required_stdout(["git", "rev-parse", "HEAD"], cwd=repo)
    tree_sha = required_stdout(["git", "rev-parse", "HEAD^{tree}"], cwd=repo)
    root_status = _status_lines(repo)
    submodule_output = required_stdout(
        ["git", "submodule", "status", "--recursive"], cwd=repo
    )
    submodules = parse_submodule_status(submodule_output)

    for submodule in submodules:
        submodule_root = repo / submodule["path"]
        if not submodule_root.is_dir():
            submodule["worktree_present"] = False
            submodule["dirty"] = None
            continue
        status = _status_lines(submodule_root)
        submodule["worktree_present"] = True
        submodule["head_sha"] = required_stdout(
            ["git", "rev-parse", "HEAD"], cwd=submodule_root
        )
        submodule["dirty"] = bool(status)
        submodule["status"] = status
        submodule["status_sha256"] = sha256_bytes(canonical_json_bytes(status))

    clean_submodules = all(
        submodule["state"] == "clean" and submodule.get("dirty") is False
        for submodule in submodules
    )
    return {
        "head_sha": head_sha,
        "path": display_path(repo),
        "reproducible_committed_state": not root_status and clean_submodules,
        "status": root_status,
        "status_sha256": sha256_bytes(canonical_json_bytes(root_status)),
        "submodules_recursive": submodules,
        "tree_sha": tree_sha,
        "worktree_dirty": bool(root_status),
    }
