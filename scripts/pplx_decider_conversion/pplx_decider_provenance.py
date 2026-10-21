"""Pinned pplx-decider source identity and artifact evidence; no MLX import or network I/O.

The decider release is pinned by the SHA-256 of its `release-manifest.json`,
which lists the bytes and SHA-256 of every weight, tokenizer and metadata file.
`LICENSE` and `NOTICE` ship at the pinned revision but are not listed in that
manifest; their digests are pinned here. The base model and the served pack
used by the conformance run have no release manifest; they are identified by
the download marker and the Hub download metadata, as in `qwen38_conversion`.
"""
from __future__ import annotations

import hashlib
import importlib.metadata
import json
import platform
import re
import struct
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


SOURCE_REPO = "perplexity-ai/pplx-decider-v1-27b"
SOURCE_REVISION = "d8c3bd18e31dc1804433d38528b3e770019bf00c"
RELEASE_MANIFEST = "release-manifest.json"
RELEASE_MANIFEST_SHA256 = "aedd35af6d2be753183b23a24c3e010c75a9ad0ff38318ee43a574b03a33c695"
EXTRA_PINS = {
    "LICENSE": "bbedc3fda3305820b977265f01b8619d87570a6739de3a5582c3464840f1e57a",
    "NOTICE": "3dff2fbb00cc77e3f9102e529b1f40af3ff9022073e24b67e4320d640e10f8e5",
}
BASE_REPO = "Qwen/Qwen3.8-27B"
BASE_REVISION = "1d4bf0f2ff6012fd82039f2fa52739d0dd7c60c0"
REFERENCE_REPO = "EigenLabs/Qwen3.8-27B-4bit"
REFERENCE_REVISION = "301e9e2767fd0efcfab7883004720ba3c9a552a1"

MARKER = ".download-complete"
INDEX = "model.safetensors.index.json"
SHA256_RE = re.compile(r"[0-9a-f]{64}\Z")
SHARD_RE = re.compile(r"model-\d{5}-of-\d{5}\.safetensors\Z")
SAFE_NAME_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*\Z")
MAX_HEADER_BYTES = 64 * 1024 * 1024


@dataclass(frozen=True)
class ReleasePolicy:
    repo: str
    revision: str
    manifest_sha256: str
    extra_pins: dict[str, str] = field(default_factory=dict)


PINNED_RELEASE = ReleasePolicy(SOURCE_REPO, SOURCE_REVISION, RELEASE_MANIFEST_SHA256, EXTRA_PINS)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def read_safetensors_header(path: Path) -> tuple[dict[str, dict[str, Any]], dict[str, str], int]:
    """Return (tensors, metadata, data_start) from a safetensors file header."""
    with path.open("rb") as handle:
        prefix = handle.read(8)
        if len(prefix) != 8:
            raise ValueError(f"truncated safetensors header: {path.name}")
        (length,) = struct.unpack("<Q", prefix)
        if length <= 0 or length > MAX_HEADER_BYTES:
            raise ValueError(f"invalid safetensors header length: {path.name}")
        raw = handle.read(length)
    if len(raw) != length:
        raise ValueError(f"truncated safetensors header: {path.name}")
    header = json.loads(raw)
    if not isinstance(header, dict):
        raise ValueError(f"invalid safetensors header: {path.name}")
    metadata = header.pop("__metadata__", None) or {}
    for name, entry in header.items():
        if (
            not isinstance(entry, dict)
            or not isinstance(entry.get("dtype"), str)
            or not isinstance(entry.get("shape"), list)
            or not isinstance(entry.get("data_offsets"), list)
            or len(entry["data_offsets"]) != 2
        ):
            raise ValueError(f"invalid safetensors tensor entry: {path.name}:{name}")
    return header, metadata, 8 + length


def _marker_error(source: Path, repo: str, revision: str) -> str | None:
    """The box downloader writes `{"repo": <repo>, "revision": <sha>}` to MARKER."""
    try:
        marker = json.loads((source / MARKER).read_text())
    except (OSError, ValueError):
        return "missing or invalid download marker"
    if not isinstance(marker, dict) or marker.get("repo") != repo or marker.get("revision") != revision:
        return "download marker repository/revision mismatch"
    return None


def _index_shards(source: Path) -> set[str]:
    index = json.loads((source / INDEX).read_text())
    weight_map = index["weight_map"]
    if not isinstance(weight_map, dict) or not all(isinstance(v, str) for v in weight_map.values()):
        raise ValueError("invalid weight_map")
    return set(weight_map.values())


def _report(source: Path, repo: str, revision: str, errors: list[str], files: dict[str, dict[str, Any]],
            shards: list[str], hash_shards: bool, checked: int, **extra: Any) -> dict[str, Any]:
    ok = not errors
    return {
        "ok": ok,
        "errors": errors,
        "repo": repo,
        "revision": revision,
        "dest": str(source),
        "verification_level": "full-shard-sha256" if hash_shards else "metadata-and-inventory",
        "source_payloads_verified": hash_shards and ok and checked == len(shards),
        "shards": shards,
        "shard_hash_checked": checked,
        "files": files,
        "marker": (source / MARKER).is_file(),
        **extra,
    }


def verify_release(
    source: Path,
    *,
    hash_shards: bool = False,
    require_shards: bool = True,
    policy: ReleasePolicy = PINNED_RELEASE,
) -> dict[str, Any]:
    """Fail closed unless every manifest-listed and extra-pinned file matches.

    Non-shard files (configs, tokenizer, readout, LICENSE, NOTICE) are always
    hashed. Weight shards are size-checked; with hash_shards=True they are
    hashed too. Without it, success never claims payload verification.
    """
    errors: list[str] = []
    files: dict[str, dict[str, Any]] = {}
    shards: list[str] = []
    checked = 0
    marker_error = _marker_error(source, policy.repo, policy.revision)
    if marker_error:
        errors.append(marker_error)
    manifest_path = source / RELEASE_MANIFEST
    manifest_sha256 = sha256_file(manifest_path) if manifest_path.is_file() else None
    entries: dict[str, Any] = {}
    if manifest_sha256 != policy.manifest_sha256:
        errors.append("release manifest missing or not the pinned manifest")
    else:
        manifest = json.loads(manifest_path.read_bytes())
        if not isinstance(manifest, dict):
            manifest = {}
        entries = manifest.get("files")
        if manifest.get("model") != policy.repo or not isinstance(entries, dict):
            errors.append("release manifest does not describe the pinned repository")
            entries = {}
    expected: dict[str, tuple[int | None, str]] = {}
    for name, entry in entries.items():
        if (
            not SAFE_NAME_RE.fullmatch(name)
            or not isinstance(entry, dict)
            or not isinstance(entry.get("bytes"), int)
            or isinstance(entry.get("bytes"), bool)
            or entry["bytes"] < 0
            or not isinstance(entry.get("sha256"), str)
            or not SHA256_RE.fullmatch(entry["sha256"])
        ):
            errors.append(f"invalid release manifest entry: {name!r}")
            continue
        expected[name] = (entry["bytes"], entry["sha256"])
    for name, digest in policy.extra_pins.items():
        expected.setdefault(name, (None, digest))

    for name, (size, digest) in sorted(expected.items()):
        path = source / name
        is_shard = bool(SHARD_RE.fullmatch(name))
        if is_shard:
            shards.append(name)
        item: dict[str, Any] = {
            "kind": "shard" if is_shard else "file",
            "expected_bytes": size,
            "expected_sha256": digest,
            "bytes": None,
            "sha256": None,
        }
        files[name] = item
        if not path.is_file():
            if not is_shard or require_shards or hash_shards:
                errors.append(f"missing source file: {name}")
            continue
        item["bytes"] = path.stat().st_size
        if size is not None and item["bytes"] != size:
            errors.append(f"source file size mismatch: {name}")
            continue
        if not is_shard:
            item["sha256"] = sha256_file(path)
            if item["sha256"] != digest:
                errors.append(f"source file hash mismatch: {name}")

    if entries:
        try:
            if _index_shards(source) != set(shards):
                errors.append("source index shards differ from release manifest")
        except (OSError, ValueError, KeyError, TypeError):
            errors.append("missing or invalid source index")

    if hash_shards and not errors:
        for name in shards:
            files[name]["sha256"] = sha256_file(source / name)
            checked += 1
            if files[name]["sha256"] != files[name]["expected_sha256"]:
                errors.append(f"source shard payload hash mismatch: {name}")
    if hash_shards and checked != len(shards):
        errors.append("full source shard hashing did not complete")
    return _report(source, policy.repo, policy.revision, errors, files, shards, hash_shards, checked,
                   release_manifest_sha256=manifest_sha256)


def _download_metadata(source: Path, name: str) -> tuple[str | None, str | None]:
    """Hub `--local-dir` metadata: line 1 commit, line 2 etag (SHA-256 for LFS)."""
    path = source / ".cache" / "huggingface" / "download" / f"{name}.metadata"
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError):
        return None, None
    return (
        lines[0].strip() if lines else None,
        lines[1].strip() if len(lines) >= 2 else None,
    )


def verify_hub_snapshot(
    source: Path, repo: str, revision: str, *, hash_shards: bool = False
) -> dict[str, Any]:
    """Identify a conformance input by marker, cached revision and LFS etags.

    Small files have git-blob etags, so only their observed SHA-256 is
    recorded. This is a qualification input, not a pinned release.
    """
    errors: list[str] = []
    files: dict[str, dict[str, Any]] = {}
    checked = 0
    marker_error = _marker_error(source, repo, revision)
    if marker_error:
        errors.append(marker_error)
    try:
        shards = sorted(_index_shards(source))
    except (OSError, ValueError, KeyError, TypeError):
        errors.append("missing or invalid source index")
        shards = []
    for name in shards:
        if not SAFE_NAME_RE.fullmatch(name):
            errors.append(f"unsafe shard name: {name!r}")
    if errors:
        return _report(source, repo, revision, errors, files, [], hash_shards, 0)
    for name in ("config.json", INDEX, *shards):
        path = source / name
        cached_revision, etag = _download_metadata(source, name)
        is_shard = name in shards
        item: dict[str, Any] = {
            "kind": "shard" if is_shard else "file",
            "expected_bytes": None,
            "expected_sha256": etag if is_shard else None,
            "bytes": path.stat().st_size if path.is_file() else None,
            "sha256": None,
        }
        files[name] = item
        if item["bytes"] is None:
            errors.append(f"missing source file: {name}")
        if cached_revision != revision:
            errors.append(f"cached revision missing or mismatched: {name}")
        if is_shard and (etag is None or not SHA256_RE.fullmatch(etag)):
            errors.append(f"missing or invalid shard SHA-256 etag: {name}")
        if not is_shard and item["bytes"] is not None:
            item["sha256"] = sha256_file(path)
    if hash_shards and not errors:
        for name in shards:
            files[name]["sha256"] = sha256_file(source / name)
            checked += 1
            if files[name]["sha256"] != files[name]["expected_sha256"]:
                errors.append(f"source shard payload hash mismatch: {name}")
    if hash_shards and checked != len(shards):
        errors.append("full source shard hashing did not complete")
    return _report(source, repo, revision, errors, files, shards, hash_shards, checked)


def runtime_provenance(core_module: Any) -> dict[str, Any]:
    """Identify the installed quantizer without logging URLs or environment."""
    distribution = importlib.metadata.distribution("mlx")
    core_path = Path(core_module.__file__).resolve()
    if not core_path.is_file() or not distribution.version:
        raise ValueError("MLX version and core module identity are required")
    metadata_digests: dict[str, str] = {}
    for name in ("METADATA", "WHEEL", "RECORD", "direct_url.json"):
        value = distribution.read_text(name)
        if value is not None:
            metadata_digests[name] = hashlib.sha256(value.encode()).hexdigest()
    return {
        "python": sys.version.split()[0],
        "python_executable": sys.executable,
        "platform": platform.platform(),
        "machine": platform.machine(),
        "mlx_distribution_version": distribution.version,
        "mlx_core_path": str(core_path),
        "mlx_core_sha256": sha256_file(core_path),
        "mlx_distribution_metadata_sha256": metadata_digests,
    }


def make_shard_manifest(
    evidence: dict[str, Any], consumed: dict[str, str], outputs: list[dict[str, Any]]
) -> dict[str, Any]:
    """Bind every consumed source payload digest to every output shard digest."""
    files = evidence["files"]
    if not evidence["ok"]:
        raise ValueError("incomplete or invalid source evidence")
    if not set(evidence["shards"]) <= set(consumed) or not set(consumed) <= set(files):
        raise ValueError("incomplete source payload coverage")
    for name, digest in consumed.items():
        if not isinstance(digest, str) or not SHA256_RE.fullmatch(digest) or digest != files[name]["expected_sha256"]:
            raise ValueError(f"unverified source digest: {name}")
    output_names = [item["file"] for item in outputs]
    if len(set(output_names)) != len(output_names) or set(output_names) != set(evidence["shards"]):
        raise ValueError("incomplete or duplicate output digest coverage")
    for item in outputs:
        if not isinstance(item.get("sha256"), str) or not SHA256_RE.fullmatch(item["sha256"]):
            raise ValueError("invalid output digest")
        if not isinstance(item.get("bytes"), int) or item["bytes"] < 0:
            raise ValueError("invalid output byte count")
    return {
        "schema_version": 1,
        "algorithm": "sha256",
        "source_repo": evidence["repo"],
        "source_revision": evidence["revision"],
        "release_manifest_sha256": evidence.get("release_manifest_sha256"),
        "source_payloads_verified": True,
        "source_payloads": [{"file": name, "sha256": consumed[name]} for name in sorted(consumed)],
        "output_shards": sorted(outputs, key=lambda item: item["file"]),
    }
