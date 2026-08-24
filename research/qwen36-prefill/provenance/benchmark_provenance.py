#!/usr/bin/env python3
"""Public API and orchestrator for Qwen benchmark provenance capture."""

from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Mapping, Sequence

from host_capture import (
    capture_competing_processes,
    capture_host,
    capture_power_and_thermal,
)
from model_capture import capture_model
from provenance_common import (
    ProvenanceError,
    canonical_json_bytes,
    capture_configuration,
    capture_environment,
    file_record,
    parse_settings,
    pretty_json,
    sha256_bytes,
    sha256_file,
)
from repository_capture import capture_repository, parse_submodule_status


SCHEMA_VERSION = 1


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace(
        "+00:00", "Z"
    )


def capture_stderr_paths(paths: Sequence[Path]) -> list[dict[str, Any]]:
    return [file_record(path, required=False) for path in paths]


def capture_document(
    *,
    repo: Path,
    binary: Path,
    metallib: Path,
    model_path: Path,
    config_paths: Sequence[Path],
    stderr_paths: Sequence[Path],
    settings: Mapping[str, dict[str, Any]],
    environment: Mapping[str, dict[str, Any]],
    registry_manifest_path: Path | None = None,
    snapshot_id: str | None = None,
    process_limit: int = 30,
    captured_at_utc: str | None = None,
) -> dict[str, Any]:
    model = capture_model(
        model_path,
        registry_manifest_path=registry_manifest_path,
        snapshot_id=snapshot_id,
    )
    return {
        "artifacts": {
            "benchmark_binary": file_record(binary),
            "metallib": file_record(metallib),
            "stderr": capture_stderr_paths(stderr_paths),
        },
        "captured_at_utc": captured_at_utc or utc_now(),
        "competing_processes": capture_competing_processes(process_limit),
        "configuration": capture_configuration(config_paths, settings, environment),
        "environment": environment,
        "host": capture_host(),
        "model": model,
        "power_and_thermal": capture_power_and_thermal(),
        "repository": capture_repository(repo),
        "schema_version": SCHEMA_VERSION,
    }
