"""Lightweight model identity capture that never reads weight payloads."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any, Mapping

from provenance_common import (
    IMMUTABLE_REVISION_RE,
    SHA256_RE,
    ProvenanceError,
    canonical_json_bytes,
    display_path,
    file_record,
    sha256_bytes,
)


def _load_registry_manifest(path: Path) -> tuple[dict[str, Any], dict[str, Any]]:
    record = file_record(path)
    try:
        raw = json.loads(path.expanduser().read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ProvenanceError(f"invalid model registry manifest: {error}") from error
    if not isinstance(raw, dict) or not isinstance(raw.get("files"), list):
        raise ProvenanceError("model registry manifest must contain a files array")

    record["metadata"] = {
        key: raw[key]
        for key in (
            "aggregate_sha256",
            "file_count",
            "model_id",
            "r2_prefix",
            "schema_version",
            "total_size_bytes",
            "version",
        )
        if key in raw
    }
    return raw, record


def _registry_files(
    manifest: Mapping[str, Any],
) -> tuple[dict[str, dict[str, Any]], list[str], bool]:
    files: dict[str, dict[str, Any]] = {}
    issues: list[str] = []
    raw_files = manifest.get("files")
    if not isinstance(raw_files, list):
        return files, ["manifest files is not an array"], False

    digest_bytes: list[tuple[str, bytes]] = []
    total_size = 0
    for index, item in enumerate(raw_files):
        if not isinstance(item, dict):
            issues.append(f"manifest file {index} is not an object")
            continue
        path = item.get("path")
        digest = item.get("sha256")
        size = item.get("size_bytes")
        if (
            not isinstance(path, str)
            or path.startswith("/")
            or ".." in Path(path).parts
            or not isinstance(digest, str)
            or not SHA256_RE.fullmatch(digest)
            or not isinstance(size, int)
            or size < 0
        ):
            issues.append(f"manifest file {index} has invalid identity fields")
            continue
        if path in files:
            issues.append(f"manifest contains duplicate path: {path}")
            continue
        files[path] = {"sha256": digest, "size_bytes": size}
        digest_bytes.append((path, bytes.fromhex(digest)))
        total_size += size

    if manifest.get("file_count") != len(raw_files):
        issues.append("manifest file_count is inconsistent")
    if manifest.get("total_size_bytes") != total_size:
        issues.append("manifest total_size_bytes is inconsistent")
    aggregate = manifest.get("aggregate_sha256")
    computed = hashlib.sha256(
        b"".join(digest for _, digest in sorted(digest_bytes))
    ).hexdigest()
    aggregate_valid = (
        isinstance(aggregate, str)
        and SHA256_RE.fullmatch(aggregate) is not None
        and aggregate == computed
        and not issues
    )
    if not aggregate_valid:
        issues.append("manifest aggregate_sha256 is missing or inconsistent")
    return files, issues, aggregate_valid


def _metadata_paths(model_path: Path) -> list[Path]:
    paths: set[Path] = set()
    for pattern in ("*config*.json", "*.safetensors.index.json"):
        paths.update(path for path in model_path.glob(pattern) if path.is_file())
    return sorted(paths, key=lambda path: path.name)


def _content_address_from_symlink(path: Path) -> str | None:
    if not path.is_symlink():
        return None
    target_name = path.resolve().name.lower()
    return target_name if SHA256_RE.fullmatch(target_name) else None


def _capture_metadata(model_path: Path) -> tuple[
    list[dict[str, Any]], dict[str, dict[str, Any]]
]:
    records: list[dict[str, Any]] = []
    by_path: dict[str, dict[str, Any]] = {}
    for path in _metadata_paths(model_path):
        relative = path.relative_to(model_path).as_posix()
        record = file_record(path)
        record["relative_path"] = relative
        records.append(record)
        by_path[relative] = record
    if "config.json" not in by_path:
        raise ProvenanceError("model directory is missing config.json")
    return records, by_path


def _capture_safetensors(
    model_path: Path,
    registry_files: Mapping[str, Mapping[str, Any]],
    has_registry: bool,
    manifest_issues: list[str],
) -> tuple[list[dict[str, Any]], bool, bool]:
    paths = sorted(
        (path for path in model_path.rglob("*.safetensors") if path.is_file()),
        key=lambda path: path.relative_to(model_path).as_posix(),
    )
    if not paths:
        raise ProvenanceError("model directory contains no safetensor shards")

    records: list[dict[str, Any]] = []
    all_content_addressed = True
    registry_covers_safetensors = has_registry
    for path in paths:
        relative = path.relative_to(model_path).as_posix()
        size = path.stat().st_size
        symlink_digest = _content_address_from_symlink(path)
        declared = registry_files.get(relative)
        declared_digest = declared["sha256"] if declared is not None else None
        if declared is None:
            registry_covers_safetensors = False
        elif declared["size_bytes"] != size:
            manifest_issues.append(f"size mismatch for {relative}")
            registry_covers_safetensors = False
        if (
            symlink_digest is not None
            and declared_digest is not None
            and symlink_digest != declared_digest
        ):
            manifest_issues.append(f"content identity mismatch for {relative}")
            registry_covers_safetensors = False

        content_digest = symlink_digest or declared_digest
        if symlink_digest is None:
            all_content_addressed = False
        records.append(
            {
                "content_sha256": content_digest,
                "content_sha256_source": (
                    "content_addressed_symlink"
                    if symlink_digest is not None
                    else "registry_manifest"
                    if declared_digest is not None
                    else None
                ),
                "relative_path": relative,
                "size_bytes": size,
            }
        )
    return records, all_content_addressed, registry_covers_safetensors


def _registry_matches_local_metadata(
    model_path: Path,
    registry_files: Mapping[str, Mapping[str, Any]],
    metadata: Mapping[str, Mapping[str, Any]],
    manifest_issues: list[str],
) -> bool:
    matches = True
    for relative, declared in registry_files.items():
        actual_path = model_path / relative
        if not actual_path.is_file():
            manifest_issues.append(f"manifest file is missing: {relative}")
            matches = False
            continue
        if actual_path.stat().st_size != declared["size_bytes"]:
            manifest_issues.append(f"manifest file size mismatch: {relative}")
            matches = False
    for relative, record in metadata.items():
        declared = registry_files.get(relative)
        if declared is None:
            manifest_issues.append(f"metadata is absent from manifest: {relative}")
            matches = False
        elif declared["sha256"] != record["sha256"]:
            manifest_issues.append(f"metadata digest mismatch: {relative}")
            matches = False
    return matches


def _snapshot_revision(model_path: Path, snapshot_id: str | None) -> str | None:
    if snapshot_id is not None:
        if not IMMUTABLE_REVISION_RE.fullmatch(snapshot_id):
            raise ProvenanceError(
                "model snapshot id must be a 40-64 hex revision or sha256:<digest>"
            )
        return snapshot_id
    for candidate in (model_path.resolve().name.lower(), model_path.name.lower()):
        if IMMUTABLE_REVISION_RE.fullmatch(candidate):
            return candidate
    return None


def capture_model(
    model_path: Path,
    *,
    registry_manifest_path: Path | None = None,
    snapshot_id: str | None = None,
) -> dict[str, Any]:
    model_path = model_path.expanduser()
    if not model_path.is_dir():
        raise ProvenanceError(f"model directory is missing: {display_path(model_path)}")

    registry_files: dict[str, dict[str, Any]] = {}
    manifest_issues: list[str] = []
    aggregate_valid = False
    registry_record: dict[str, Any] | None = None
    manifest: dict[str, Any] | None = None
    if registry_manifest_path is not None:
        manifest, registry_record = _load_registry_manifest(registry_manifest_path)
        registry_files, manifest_issues, aggregate_valid = _registry_files(manifest)

    metadata_records, metadata_by_path = _capture_metadata(model_path)
    safetensor_records, all_content_addressed, registry_covers_safetensors = (
        _capture_safetensors(
            model_path,
            registry_files,
            registry_manifest_path is not None,
            manifest_issues,
        )
    )
    registry_matches = (
        _registry_matches_local_metadata(
            model_path, registry_files, metadata_by_path, manifest_issues
        )
        if manifest is not None
        else False
    )
    revision = _snapshot_revision(model_path, snapshot_id)

    registry_identity_complete = (
        aggregate_valid
        and registry_covers_safetensors
        and registry_matches
        and not manifest_issues
    )
    if registry_identity_complete:
        identity = {
            "complete": True,
            "id": manifest["aggregate_sha256"],
            "source": "registry_manifest_aggregate_sha256",
            "weight_bytes_rehashed": False,
        }
    elif all_content_addressed:
        identity = {
            "complete": True,
            "id": sha256_bytes(canonical_json_bytes(safetensor_records)),
            "source": "content_addressed_safetensor_symlinks",
            "weight_bytes_rehashed": False,
        }
    elif revision is not None:
        identity = {
            "complete": True,
            "id": revision,
            "source": "immutable_snapshot_revision",
            "weight_bytes_rehashed": False,
        }
    else:
        identity = {
            "complete": False,
            "id": None,
            "reason": (
                "local snapshot alias has neither an immutable revision, "
                "content-addressed shard symlinks, nor a complete registry manifest"
            ),
            "source": "incomplete",
            "weight_bytes_rehashed": False,
        }

    safetensor_manifest = [
        {
            "content_sha256": record["content_sha256"],
            "relative_path": record["relative_path"],
            "size_bytes": record["size_bytes"],
        }
        for record in safetensor_records
    ]
    result: dict[str, Any] = {
        "identity": identity,
        "metadata_files": metadata_records,
        "path": display_path(model_path),
        "resolved_path": display_path(model_path.resolve()),
        "safetensors": {
            "file_count": len(safetensor_records),
            "files": safetensor_records,
            "manifest_sha256": sha256_bytes(canonical_json_bytes(safetensor_manifest)),
            "total_size_bytes": sum(
                record["size_bytes"] for record in safetensor_records
            ),
            "weight_bytes_rehashed": False,
        },
    }
    if registry_record is not None:
        registry_record["issues"] = sorted(set(manifest_issues))
        registry_record["self_consistent"] = aggregate_valid
        result["registry_manifest"] = registry_record
    return result
