"""Bounded offline snapshot discovery and launch artifact provenance."""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import stat
from typing import Any

from .constants import (
    MAX_CACHE_ROOTS, MAX_FALLBACK_REPOSITORY_ENTRIES, MAX_FALLBACK_REPOSITORIES,
    MAX_SNAPSHOT_ENTRIES, MAX_REF_BYTES, HEX_DIGITS,
)
from .run_directory import read_bounded

def repo_cache_name(model_id: str) -> str:
    return "models--" + model_id.replace("/", "--")


def bounded_scandir(directory: Path, limit: int) -> tuple[list[os.DirEntry[str]], bool]:
    entries: list[os.DirEntry[str]] = []
    with os.scandir(directory) as iterator:
        for entry in iterator:
            if len(entries) >= limit:
                return entries, True
            entries.append(entry)
    return entries, False


def cache_roots() -> list[Path]:
    candidates: list[Path] = []
    if value := os.environ.get("HUGGINGFACE_HUB_CACHE"):
        candidates.append(Path(value).expanduser())
    if value := os.environ.get("HF_HOME"):
        candidates.append(Path(value).expanduser() / "hub")
    candidates.extend(
        [
            Path.home() / ".cache/huggingface/hub",
            Path.home() / "Library/Caches/huggingface/hub",
        ]
    )
    roots: list[Path] = []
    for candidate in candidates[:MAX_CACHE_ROOTS]:
        try:
            resolved = candidate.resolve(strict=True)
        except OSError:
            continue
        if resolved.is_dir() and resolved not in roots:
            roots.append(resolved)
    return roots


def confined_regular_file(path: Path, repository: Path) -> Path:
    resolved = path.resolve(strict=True)
    resolved_repository = repository.resolve(strict=True)
    if resolved != resolved_repository and resolved_repository not in resolved.parents:
        raise OSError(f"file escapes cache repository: {path}")
    metadata = resolved.stat()
    if not stat.S_ISREG(metadata.st_mode):
        raise OSError(f"not a regular file: {path}")
    return resolved


def repository_snapshot(repository: Path) -> Path | None:
    try:
        repository_metadata = repository.lstat()
        if not stat.S_ISDIR(repository_metadata.st_mode):
            return None
        ref = confined_regular_file(repository / "refs/main", repository)
        if ref.stat().st_size > MAX_REF_BYTES:
            return None
        revision = ref.read_bytes()[: MAX_REF_BYTES + 1].decode().strip()
        if (
            not revision
            or len(revision) > 128
            or revision in {".", ".."}
            or "/" in revision
        ):
            return None
        snapshot = repository / "snapshots" / revision
        snapshot_metadata = snapshot.lstat()
        if not stat.S_ISDIR(snapshot_metadata.st_mode):
            return None
        confined_regular_file(snapshot / "config.json", repository)
        entries, truncated = bounded_scandir(snapshot, MAX_SNAPSHOT_ENTRIES)
        if truncated:
            raise OSError(
                f"snapshot entry scan exceeds {MAX_SNAPSHOT_ENTRIES}: {snapshot}"
            )
        if not any(
            entry.name.endswith(".safetensors")
            and stat.S_ISREG(
                confined_regular_file(Path(entry.path), repository).stat().st_mode
            )
            for entry in entries
        ):
            return None
        return snapshot.resolve(strict=True)
    except (OSError, UnicodeDecodeError):
        return None


def resolve_cached_snapshot(model_id: str) -> Path:
    wanted_name = repo_cache_name(model_id)
    roots = cache_roots()

    # Hugging Face repository directory names are deterministic. Resolve the
    # exact path first so the normal path never scans an entire cache root.
    for root in roots:
        if snapshot := repository_snapshot(root / wanted_name):
            return snapshot

    fallback_repositories = 0
    for root in roots:
        try:
            entries, truncated = bounded_scandir(
                root, MAX_FALLBACK_REPOSITORY_ENTRIES
            )
        except OSError:
            continue
        if truncated:
            raise SystemExit(
                "exact cache repository was absent and bounded fallback scan "
                f"exceeded {MAX_FALLBACK_REPOSITORY_ENTRIES} entries at {root}"
            )
        for entry in entries:
            if entry.name.lower() != wanted_name.lower():
                continue
            if not entry.is_dir(follow_symlinks=False):
                continue
            fallback_repositories += 1
            if fallback_repositories > MAX_FALLBACK_REPOSITORIES:
                raise SystemExit(
                    f"fallback cache resolution exceeded {MAX_FALLBACK_REPOSITORIES} repositories"
                )
            if snapshot := repository_snapshot(Path(entry.path)):
                return snapshot
    raise SystemExit(f"cached main snapshot not found for {model_id}; downloads are forbidden")


def validate_snapshot(path: Path, label: str) -> Path:
    resolved = path.expanduser().resolve(strict=True)
    metadata = resolved.lstat()
    if not stat.S_ISDIR(metadata.st_mode):
        raise SystemExit(f"{label} path is not a real snapshot directory: {resolved}")
    repository = resolved.parent.parent
    try:
        confined_regular_file(resolved / "config.json", repository)
        entries, truncated = bounded_scandir(resolved, MAX_SNAPSHOT_ENTRIES)
        if truncated:
            raise OSError(f"snapshot contains over {MAX_SNAPSHOT_ENTRIES} entries")
        if not any(
            entry.name.endswith(".safetensors")
            and confined_regular_file(Path(entry.path), repository)
            for entry in entries
        ):
            raise OSError("no safetensors weights")
    except OSError as error:
        raise SystemExit(f"{label} path is not a complete cached snapshot: {error}")
    return resolved


def infer_huggingface_model_id(snapshot: Path) -> str | None:
    if snapshot.parent.name != "snapshots":
        return None
    repository_name = snapshot.parent.parent.name
    if not repository_name.startswith("models--"):
        return None
    components = repository_name.removeprefix("models--").split("--")
    if len(components) < 2 or not all(components):
        return None
    return "/".join(components)


def resolve_model_snapshot(
    explicit_id: str | None,
    explicit_path: Path | None,
    default_id: str,
    label: str,
) -> tuple[str, Path]:
    if explicit_path is None:
        model_id = explicit_id or default_id
        return model_id, validate_snapshot(resolve_cached_snapshot(model_id), label)
    snapshot = validate_snapshot(explicit_path, label)
    inferred_id = infer_huggingface_model_id(snapshot)
    if explicit_id is not None and inferred_id is not None and explicit_id != inferred_id:
        raise SystemExit(f"{label} model ID does not match its Hugging Face snapshot path")
    if explicit_id is None and inferred_id is None:
        raise SystemExit(f"--{label}-id is required for a non-Hugging-Face explicit path")
    return explicit_id or inferred_id or default_id, snapshot


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def append_fingerprint_field(payload: bytearray, value: str) -> None:
    encoded = value.encode()
    payload.extend(len(encoded).to_bytes(8, "big"))
    payload.extend(encoded)


def collect_nested_bit_overrides(value: Any, counts: dict[int, int]) -> None:
    """Mirror of MTPBenchmarkModelFacts.collectNestedBitOverrides: count every
    nested object carrying an integer `bits` anywhere under the quantization
    dictionary's values."""
    if isinstance(value, dict):
        bits = value.get("bits")
        if isinstance(bits, int) and not isinstance(bits, bool):
            counts[bits] = counts.get(bits, 0) + 1
        for child in value.values():
            collect_nested_bit_overrides(child, counts)
    elif isinstance(value, list):
        for child in value:
            collect_nested_bit_overrides(child, counts)


def launch_effective_quantization_bits(raw_quantization: Any) -> int | None:
    """Launch-side twin of `effective_quantization_bits`, computed from the
    hashed config bytes: top-level integer `bits` wins; otherwise a UNIQUE
    nested override value (per-layer `bits`) is the effective width."""
    if not isinstance(raw_quantization, dict):
        return None
    bits = raw_quantization.get("bits")
    if isinstance(bits, int) and not isinstance(bits, bool):
        return bits
    counts: dict[int, int] = {}
    for value in raw_quantization.values():
        collect_nested_bit_overrides(value, counts)
    unique = {value for value, count in counts.items() if count > 0}
    return next(iter(unique)) if len(unique) == 1 else None


def artifact_facts(model_id: str, snapshot: Path) -> dict[str, Any]:
    repository = snapshot.parent.parent
    config = confined_regular_file(snapshot / "config.json", repository)
    config_size = config.stat().st_size
    if config_size > 4 * 1024 * 1024:
        raise ValueError("config.json exceeds the 4 MiB launch-side cap")
    # Independently parse the coverage-relevant metadata from the SAME bytes
    # that were hashed, so the supervisor's coverage gates do not depend
    # solely on the Swift inspector's transcription of these fields.
    with open(config, "rb") as handle:
        config_bytes = read_bounded(handle.fileno(), 4 * 1024 * 1024)
    config_size = len(config_bytes)
    config_digest = hashlib.sha256(config_bytes).hexdigest()
    parsed = json.loads(config_bytes)
    if not isinstance(parsed, dict):
        raise ValueError("config.json root is not an object")
    # Mirrors MTPBenchmarkModelFacts.swift: "quantization" falls back to the HF "quantization_config" key.
    raw_quantization = parsed.get("quantization")
    if not isinstance(raw_quantization, dict):
        raw_quantization = parsed.get("quantization_config")
    config_metadata = {
        "model_type": parsed.get("model_type"),
        "dtype": parsed.get("dtype"),
        "effective_quantization_bits": launch_effective_quantization_bits(raw_quantization),
        "has_quantization": isinstance(raw_quantization, dict),
    }
    entries, truncated = bounded_scandir(snapshot, MAX_SNAPSHOT_ENTRIES)
    if truncated:
        raise ValueError(f"snapshot entry scan exceeds {MAX_SNAPSHOT_ENTRIES}")
    weights: list[dict[str, Any]] = []
    for entry in sorted(entries, key=lambda value: value.name):
        if not entry.name.endswith(".safetensors"):
            continue
        source = Path(entry.path)
        resolved = confined_regular_file(source, repository)
        candidate = resolved.name.lower()
        if (
            entry.is_symlink()
            and snapshot.parent.name == "snapshots"
            and resolved.parent == repository / "blobs"
            and set(candidate) <= HEX_DIGITS
            and len(candidate) in {40, 64}
        ):
            kind = "hf_blob_sha256" if len(candidate) == 64 else "hf_blob_git_sha1"
            identity = candidate
        else:
            kind = "sha256"
            identity = sha256_file(resolved)
        weights.append(
            {
                "name": entry.name,
                "sizeBytes": resolved.stat().st_size,
                "identityKind": kind,
                "contentIdentity": identity,
            }
        )
    if not weights:
        raise ValueError("artifact has no safetensors weights")
    revision = (
        snapshot.name.lower()
        if len(snapshot.name) == 40 and set(snapshot.name.lower()) <= HEX_DIGITS
        else None
    )
    payload = bytearray(b"darkbloom.mtp.artifact-fingerprint.v1")
    for value in (model_id, revision or "", str(config_size), config_digest):
        append_fingerprint_field(payload, value)
    for weight in weights:
        for value in (
            weight["name"],
            str(weight["sizeBytes"]),
            weight["identityKind"],
            weight["contentIdentity"],
        ):
            append_fingerprint_field(payload, value)
    return {
        "modelID": model_id,
        "resolvedPath": str(snapshot),
        "revision": revision,
        "configSizeBytes": config_size,
        "configSHA256": config_digest,
        "configMetadata": config_metadata,
        "weightFiles": weights,
        "artifactFingerprint": hashlib.sha256(payload).hexdigest(),
    }


