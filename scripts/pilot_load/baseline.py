from __future__ import annotations

import hashlib
import json
import os
import tempfile
from pathlib import Path
from typing import Any

from .config import Profile
from .evidence import TOOL_NAME, TOOL_VERSION
from .baseline_validation import (
    BASELINE_SCHEMA_VERSION,
    FIXTURE_SCHEMA_VERSION,
    MINIMUM_MEASUREMENT_SAMPLES,
    is_commit,
    is_sha256,
    validate_measurement,
)


MEASUREMENT_FIELDS = (
    "generated_at",
    "profile",
    "source",
    "source_commit",
    "tool",
    "environment",
    "execution_environment",
    "inputs",
    "executables",
    "ci",
    "schemas",
    "source_report",
    "sample_thresholds",
    "targets",
    "resources",
    "review",
)


def create_baseline(
    report_path: Path,
    baseline_path: Path,
    fixture_path: Path,
    profile: Profile,
    generator_metadata: dict[str, Any],
    repo_root: Path,
    *,
    candidate: bool = False,
) -> tuple[Path, Path]:
    report_bytes = report_path.read_bytes()
    try:
        report = json.loads(report_bytes)
    except json.JSONDecodeError as error:
        raise ValueError(f"baseline source report is invalid JSON: {error}") from error
    measurement = _measurement_from_report(
        report,
        profile,
        report_path,
        report_bytes,
        repo_root,
    )
    validate_measurement(measurement, profile)
    review_status = "candidate" if candidate else "reviewed"
    _validate_review_transition(
        measurement,
        profile,
        generator_metadata,
        candidate=candidate,
    )
    measurement["review"] = _review_provenance(review_status, generator_metadata)
    fixture = {
        "schema_version": FIXTURE_SCHEMA_VERSION,
        "fixture_version": 1,
        **measurement,
    }
    fixture_path.parent.mkdir(parents=True, exist_ok=True)
    _atomic_json(fixture_path, fixture)
    fixture_reference = _relative_fixture_path(baseline_path, fixture_path)
    baseline = {
        "schema_version": BASELINE_SCHEMA_VERSION,
        "baseline_version": 3,
        "source_fixture": {
            "path": fixture_reference,
            "sha256": _sha256(fixture_path),
            "schema_version": FIXTURE_SCHEMA_VERSION,
        },
        "generator": _generator_provenance(generator_metadata),
        **measurement,
    }
    baseline_path.parent.mkdir(parents=True, exist_ok=True)
    _atomic_json(baseline_path, baseline)
    return baseline_path, fixture_path


def load_baseline(path: Path | None, profile: Profile) -> dict[str, Any]:
    if path is None:
        raise ValueError("a committed versioned baseline is required")
    document = _load_json(path, "baseline")
    if document.get("schema_version") != BASELINE_SCHEMA_VERSION:
        raise ValueError(
            f"baseline must use schema_version {BASELINE_SCHEMA_VERSION}"
        )
    if document.get("baseline_version") != 3:
        raise ValueError("baseline_version must be 3")
    fixture_reference = document.get("source_fixture")
    if not isinstance(fixture_reference, dict):
        raise ValueError("baseline requires a hash-pinned source_fixture")
    relative = fixture_reference.get("path")
    if (
        not isinstance(relative, str)
        or not relative
        or Path(relative).is_absolute()
        or ".." in Path(relative).parts
    ):
        raise ValueError("baseline source_fixture path must be relative and contained")
    fixture_path = (path.parent / relative).resolve()
    if not fixture_path.is_relative_to(path.parent.resolve()) or not fixture_path.is_file():
        raise ValueError("baseline source fixture is unavailable")
    expected_hash = fixture_reference.get("sha256")
    if not is_sha256(expected_hash) or _sha256(fixture_path) != expected_hash:
        raise ValueError("baseline source fixture hash mismatch")
    fixture = _load_json(fixture_path, "baseline source fixture")
    if (
        fixture.get("schema_version") != FIXTURE_SCHEMA_VERSION
        or fixture_reference.get("schema_version") != FIXTURE_SCHEMA_VERSION
        or fixture.get("fixture_version") != 1
    ):
        raise ValueError("baseline source fixture schema is unsupported")
    for field in MEASUREMENT_FIELDS:
        if document.get(field) != fixture.get(field):
            raise ValueError(
                f"baseline field {field!r} does not match its source fixture"
            )
    review = document.get("review")
    if not isinstance(review, dict) or review.get("status") != "reviewed":
        raise ValueError("baseline is an unreviewed non-authorizing candidate")
    generator = document.get("generator")
    if not isinstance(generator, dict):
        raise ValueError("baseline generator provenance is missing")
    generator_tool = generator.get("tool")
    if (
        not isinstance(generator_tool, dict)
        or generator_tool.get("name") != TOOL_NAME
        or generator_tool.get("version") != TOOL_VERSION
        or not is_sha256(generator_tool.get("source_sha256"))
    ):
        raise ValueError("baseline generator tool provenance is invalid")
    generator_source = generator.get("source")
    if (
        not isinstance(generator_source, dict)
        or not is_commit(generator_source.get("commit"))
        or review.get("generator_source_commit") != generator_source.get("commit")
    ):
        raise ValueError("baseline review provenance does not match its generator")
    validate_measurement(document, profile)
    return document


def validate_baseline_for_run(
    baseline: dict[str, Any],
    profile: Profile,
    current_provenance: dict[str, Any],
) -> None:
    if profile.name != "scheduled":
        return
    source = baseline.get("source")
    source_ci = baseline.get("ci")
    current_source = current_provenance.get("source")
    current_ci = current_provenance.get("ci")
    if not all(
        isinstance(value, dict)
        for value in (source, source_ci, current_source, current_ci)
    ):
        raise ValueError("scheduled baseline run provenance is incomplete")
    source_commit = source.get("commit")
    current_commit = current_source.get("commit")
    source_run = source_ci.get("run_id")
    current_run = current_ci.get("run_id")
    if source_ci.get("provider") != "github-actions" or not source_run:
        raise ValueError("scheduled baseline must originate from a prior CI run")
    if source_commit == current_commit:
        raise ValueError("scheduled baseline source commit must differ from the current run")
    if current_ci.get("provider") == "github-actions" and source_run == current_run:
        raise ValueError("scheduled baseline source run must differ from the current run")


def _measurement_from_report(
    report: dict[str, Any],
    profile: Profile,
    report_path: Path,
    report_bytes: bytes,
    repo_root: Path,
) -> dict[str, Any]:
    if report.get("schema_version") != 1:
        raise ValueError("baseline source report must use schema_version 1")
    gate_failures = report.get("gate_failures")
    if not isinstance(gate_failures, list) or any(
        not _is_regression_gate_failure(failure) for failure in gate_failures
    ):
        raise ValueError(
            "baseline source report may fail only its previous regression baseline"
        )
    if report.get("verdict") not in {
        "pass",
        "fail",
        "baseline_review_required",
    } or report.get("skipped_scenarios"):
        raise ValueError("baseline source report has invalid or skipped gate results")
    comparison = report.get("comparison")
    if (
        not isinstance(comparison, dict)
        or comparison.get("passed") is not True
        or comparison.get("differences")
    ):
        raise ValueError("baseline source report must pass differential comparison")
    report_profile = report.get("profile")
    if (
        not isinstance(report_profile, dict)
        or report_profile.get("name") != profile.name
        or report_profile.get("seed") != profile.seed
        or report_profile.get("duration_seconds") != profile.duration_seconds
        or report_profile.get("soak") is not profile.soak
        or report_profile.get("request_count") != profile.request_count
        or report_profile.get("websocket_sessions") != profile.websocket_sessions
        or report_profile.get("concurrency_ramp") != list(profile.concurrency_ramp)
    ):
        raise ValueError("baseline source report profile does not match")
    metadata = report.get("metadata")
    if not isinstance(metadata, dict):
        raise ValueError("baseline source report metadata is missing")
    source = metadata.get("source")
    tool = metadata.get("tool")
    environment = metadata.get("runner_image")
    ci = metadata.get("ci")
    if not all(isinstance(value, dict) for value in (source, tool, environment, ci)):
        raise ValueError("baseline source report provenance is incomplete")
    source_commit = source.get("commit")
    source_baseline_mode = metadata.get("regression_baseline_mode")
    if source_baseline_mode not in {"capture", "measured"}:
        raise ValueError("baseline source report did not measure baseline state")
    if source_baseline_mode == "capture" and (
        report.get("verdict") != "baseline_review_required"
        or report.get("authorization_eligible") is not False
    ):
        raise ValueError(
            "capture source report must be explicitly non-authorizing"
        )
    resources = report.get("resources")
    if not isinstance(resources, dict):
        raise ValueError("baseline source report resources are missing")
    database_pool_max = metadata.get("database_pool_max")
    if not isinstance(database_pool_max, dict):
        databases = resources.get("databases", {})
        database_pool_max = {
            name: databases.get(name, {}).get("pool_max")
            for name in ("go", "rust")
        }
    input_artifacts = metadata.get("input_artifacts")
    executable_artifacts = metadata.get("executable_artifacts")
    if not isinstance(input_artifacts, dict) or not isinstance(
        executable_artifacts, dict
    ):
        raise ValueError("baseline source report artifact provenance is incomplete")
    if profile.soak:
        targets = report.get("targets")
        if not isinstance(targets, dict) or any(
            not isinstance(targets.get(name), dict)
            or not isinstance(targets[name].get("load_elapsed_seconds"), (int, float))
            or isinstance(targets[name].get("load_elapsed_seconds"), bool)
            or targets[name]["load_elapsed_seconds"] < profile.duration_seconds
            for name in ("go", "rust")
        ):
            raise ValueError(
                "baseline source report does not contain the full configured soak"
            )
    display_path = _display_path(report_path, repo_root)
    return {
        "generated_at": report.get("generated_at"),
        "profile": {
            "name": profile.name,
            "seed": profile.seed,
            "request_count": profile.request_count,
            "websocket_sessions": profile.websocket_sessions,
            "concurrency_ramp": list(profile.concurrency_ramp),
        },
        "source": source,
        "source_commit": source_commit,
        "tool": tool,
        "environment": environment,
        "execution_environment": {
            "database_pool_max": database_pool_max,
            "source_baseline_mode": source_baseline_mode,
        },
        "inputs": {
            name: value
            for name, value in input_artifacts.items()
            if name != "baseline"
        },
        "executables": executable_artifacts,
        "ci": ci,
        "schemas": {
            "report": 1,
            "baseline": BASELINE_SCHEMA_VERSION,
            "fixture": FIXTURE_SCHEMA_VERSION,
        },
        "source_report": {
            "path": display_path,
            "sha256": hashlib.sha256(report_bytes).hexdigest(),
            "size_bytes": len(report_bytes),
        },
        "sample_thresholds": {
            "p50": MINIMUM_MEASUREMENT_SAMPLES,
            "p95": MINIMUM_MEASUREMENT_SAMPLES,
            "p99": MINIMUM_MEASUREMENT_SAMPLES,
            "max": MINIMUM_MEASUREMENT_SAMPLES,
        },
        "targets": report.get("targets"),
        "resources": resources,
    }


def _generator_provenance(metadata: dict[str, Any]) -> dict[str, Any]:
    tool = metadata.get("tool")
    source = metadata.get("source")
    if not isinstance(tool, dict) or not isinstance(source, dict):
        raise ValueError("baseline generator provenance is unavailable")
    return {
        "tool": tool,
        "source": source,
        "environment": metadata.get("runner_image"),
    }


def _review_provenance(
    status: str,
    generator_metadata: dict[str, Any],
) -> dict[str, Any]:
    source = generator_metadata.get("source")
    ci = generator_metadata.get("ci")
    return {
        "status": status,
        "generator_source_commit": source.get("commit") if isinstance(source, dict) else None,
        "generator_run_id": ci.get("run_id") if isinstance(ci, dict) else None,
    }


def _validate_review_transition(
    measurement: dict[str, Any],
    profile: Profile,
    generator_metadata: dict[str, Any],
    *,
    candidate: bool,
) -> None:
    source_mode = measurement["execution_environment"]["source_baseline_mode"]
    if candidate:
        if profile.name != "scheduled" or source_mode != "capture":
            raise ValueError(
                "candidate baselines require a scheduled capture-only source report"
            )
        return
    if profile.name != "scheduled":
        return
    source_ci = measurement.get("ci")
    if (
        not isinstance(source_ci, dict)
        or source_ci.get("provider") != "github-actions"
        or not source_ci.get("run_id")
    ):
        raise ValueError("reviewed scheduled baseline requires a prior CI source run")


def _relative_fixture_path(baseline_path: Path, fixture_path: Path) -> str:
    baseline_parent = baseline_path.resolve().parent
    fixture = fixture_path.resolve()
    if not fixture.is_relative_to(baseline_parent):
        raise ValueError("baseline source fixture must be inside the baseline directory")
    return fixture.relative_to(baseline_parent).as_posix()


def _display_path(path: Path, root: Path) -> str:
    try:
        return path.resolve().relative_to(root.resolve()).as_posix()
    except ValueError:
        return path.name


def _load_json(path: Path, label: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise ValueError(f"{label} is unavailable: {path}") from error
    except json.JSONDecodeError as error:
        raise ValueError(f"{label} is invalid JSON: {error}") from error
    if not isinstance(value, dict):
        raise ValueError(f"{label} must be a JSON object")
    return value


def _atomic_json(path: Path, value: dict[str, Any]) -> None:
    content = json.dumps(value, indent=2, sort_keys=True) + "\n"
    descriptor, temporary = tempfile.mkstemp(
        prefix=path.name + ".",
        dir=path.parent,
        text=True,
    )
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _is_regression_gate_failure(value: Any) -> bool:
    if not isinstance(value, dict):
        return False
    gate = value.get("gate")
    return isinstance(gate, str) and (
        ".baseline." in gate or gate.startswith("resources.baseline")
    )
