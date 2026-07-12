from __future__ import annotations

import hashlib
import json
import os
import platform
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


TOOL_NAME = "darkbloom-objective9-pilot"
TOOL_VERSION = "2.7.0"
EVIDENCE_SCHEMA_VERSION = 1


def runtime_metadata(repo_root: Path) -> dict[str, Any]:
    in_github_actions = os.environ.get("GITHUB_ACTIONS") == "true"
    commit = os.environ.get("GITHUB_SHA") or _git_commit(repo_root)
    workflow_repository = os.environ.get("GITHUB_REPOSITORY") if in_github_actions else None
    server = os.environ.get("GITHUB_SERVER_URL", "https://github.com")
    run_id = os.environ.get("GITHUB_RUN_ID")
    run_url = (
        f"{server}/{workflow_repository}/actions/runs/{run_id}"
        if workflow_repository and run_id
        else None
    )
    image_metadata = {
        key.lower(): value
        for key, value in (
            ("image_os", os.environ.get("ImageOS")),
            ("image_version", os.environ.get("ImageVersion")),
            ("runner_arch", os.environ.get("RUNNER_ARCH")),
            ("runner_os", os.environ.get("RUNNER_OS")),
            ("runner_environment", os.environ.get("RUNNER_ENVIRONMENT")),
            ("runner_name", os.environ.get("RUNNER_NAME")),
        )
        if value
    }
    image_metadata.update(
        {
            "platform": platform.platform(),
            "machine": platform.machine(),
            "kernel_release": platform.release(),
            "os_release": _os_release(),
        }
    )
    metadata = {
        "tool": {
            "name": TOOL_NAME,
            "version": TOOL_VERSION,
            "python": sys.version.split()[0],
            "source_sha256": _tool_source_sha256(repo_root),
        },
        "source": {
            "commit": commit,
            "repository": workflow_repository,
            "ref": os.environ.get("GITHUB_REF") if in_github_actions else None,
            "tracked_worktree_dirty": _git_tracked_dirty(repo_root),
        },
        "ci": {
            "provider": "github-actions" if in_github_actions else "local",
            "workflow": os.environ.get("GITHUB_WORKFLOW") if in_github_actions else None,
            "workflow_ref": os.environ.get("GITHUB_WORKFLOW_REF") if in_github_actions else None,
            "job": os.environ.get("GITHUB_JOB") if in_github_actions else None,
            "run_id": run_id,
            "run_attempt": os.environ.get("GITHUB_RUN_ATTEMPT") if in_github_actions else None,
            "run_url": run_url,
            "actor": os.environ.get("GITHUB_ACTOR") if in_github_actions else None,
            "oidc_issuer": "https://token.actions.githubusercontent.com",
            "oidc_audience": "sigstore",
        },
        "runner_image": image_metadata,
    }
    if in_github_actions:
        _validate_ci_metadata(metadata)
    return metadata


def write_evidence(
    report_path: Path,
    markdown_path: Path,
    provenance: dict[str, Any],
    *,
    profile_name: str,
    minimum_samples: dict[str, int],
    authorizing: bool = True,
) -> Path:
    evidence_path = report_path.with_name("evidence.json")
    document = {
        "schema_version": EVIDENCE_SCHEMA_VERSION,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "tool": provenance.get("tool"),
        "source": provenance.get("source"),
        "ci": provenance.get("ci"),
        "runner_image": provenance.get("runner_image"),
        "profile": profile_name,
        "sample_thresholds": minimum_samples,
        "authorization": {
            "eligible": authorizing,
            "reason": "measured_baseline" if authorizing else "baseline_review_required",
        },
        "artifacts": {
            report_path.name: artifact_metadata(report_path),
            markdown_path.name: artifact_metadata(markdown_path),
        },
        "signature": {
            "format": "sigstore-bundle-v0.3",
            "bundle_file": "evidence.sigstore.json",
            "required_in_ci": (
                authorizing
                and provenance.get("ci", {}).get("provider") == "github-actions"
            ),
            "identity_issuer": "https://token.actions.githubusercontent.com",
        },
    }
    evidence_path.write_text(
        json.dumps(document, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    evidence_path.with_suffix(".json.sha256").write_text(
        f"{_sha256(evidence_path)}  {evidence_path.name}\n",
        encoding="utf-8",
    )
    return evidence_path


def artifact_metadata(path: Path) -> dict[str, Any]:
    return {"sha256": _sha256(path), "size_bytes": path.stat().st_size}


def _validate_ci_metadata(metadata: dict[str, Any]) -> None:
    source = metadata["source"]
    ci = metadata["ci"]
    commit = source.get("commit")
    if not isinstance(commit, str) or re.fullmatch(r"[0-9a-fA-F]{40,64}", commit) is None:
        raise ValueError("GitHub Actions evidence requires a full commit ID")
    if source.get("tracked_worktree_dirty") is not False:
        raise ValueError("GitHub Actions evidence requires a clean tracked worktree")
    for name in ("repository", "ref"):
        if not isinstance(source.get(name), str) or not source[name]:
            raise ValueError(f"GitHub Actions evidence requires source.{name}")
    for name in ("workflow", "workflow_ref", "job", "run_id", "run_attempt", "run_url", "actor"):
        if not isinstance(ci.get(name), str) or not ci[name]:
            raise ValueError(f"GitHub Actions evidence requires ci.{name}")


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _git_commit(repo_root: Path) -> str | None:
    try:
        completed = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=repo_root,
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=5,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    value = completed.stdout.strip()
    return value or None


def _git_tracked_dirty(repo_root: Path) -> bool | None:
    try:
        unstaged = subprocess.run(
            ["git", "diff", "--quiet", "--"],
            cwd=repo_root,
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=5,
        )
        staged = subprocess.run(
            ["git", "diff", "--cached", "--quiet", "--"],
            cwd=repo_root,
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=5,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if unstaged.returncode not in {0, 1} or staged.returncode not in {0, 1}:
        return None
    return unstaged.returncode == 1 or staged.returncode == 1


def _tool_source_sha256(repo_root: Path) -> str:
    paths = [repo_root / "scripts/pilot-load.py"]
    paths.extend(sorted((repo_root / "scripts/pilot_load").glob("*.py")))
    digest = hashlib.sha256()
    for path in paths:
        if not path.is_file():
            continue
        relative = path.relative_to(repo_root).as_posix().encode()
        digest.update(len(relative).to_bytes(4, "big"))
        digest.update(relative)
        content = path.read_bytes()
        digest.update(len(content).to_bytes(8, "big"))
        digest.update(content)
    return digest.hexdigest()


def _os_release() -> dict[str, str]:
    path = Path("/etc/os-release")
    if not path.is_file():
        return {}
    values: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        name, separator, value = line.partition("=")
        if separator and name in {"ID", "VERSION_ID", "BUILD_ID", "IMAGE_ID", "IMAGE_VERSION"}:
            values[name.lower()] = value.strip().strip('"')
    return values
