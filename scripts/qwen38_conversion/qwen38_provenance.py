"""Pinned Qwen source identity and artifact evidence; no MLX import or network I/O.

These checks describe a future conversion or an explicit verification run.
They do not upgrade the historical September 10 artifact's evidence.
"""
from __future__ import annotations

import hashlib
import importlib.metadata
import json
import platform
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any


SOURCE_REPO = "Qwen/Qwen3.8-Flash-Next"
SOURCE_REVISION = "de4b8e4d43b917e7706784d8bb445c9af86a3540"
METADATA_PINS = {
    "config.json": "889658f2508e8c61d409b02e70e0d78d8d4452ec65aaafbe129805d213d2e74b",
    "model.safetensors.index.json": "99e815241ef03325536b0aaa4441deea45174c17fae31e10f0bb456410c590de",
    "LICENSE": "a0dc422560841fd68e06d974907f8b4c709bca44a67daad2b528437bdf676c08",
    "chat_template.jinja": "c3cf9e34abf4f9e36c2d72165aa9c132d3e2a725b6c2586aaa3a8af9d7a81041",
    "generation_config.json": "e70c136c1b78ddc1fb0905bac8e733a4dc448d4f852a5dd75143fffc70be550e",
    "tokenizer.json": "0997f410c57a1f4e53b09e4be8f4a172d90edd9564368fb0847030937229b9f3",
    "tokenizer_config.json": "b11349aafa7cdc6a320767cf7ceb29ed82f7eda5d65e8e0819e76f0ce947bf27",
    "vocab.json": "ce99b4cb2983d118806ce0a8b777a35b093e2000a503ebde25853284c9dfa003",
    "preprocessor_config.json": "27225450ac9c6529872ee1924fcb0962ff5634834f817040f444118116f4e516",
    "video_preprocessor_config.json": "7768af27c1fafa9cc9011c1dc20067e03f8915e03b63504550e11d5066986d13",
}
SHA256_RE = re.compile(r"[0-9a-f]{64}\Z")


@dataclass(frozen=True)
class SourcePolicy:
    repo: str
    revision: str
    metadata_pins: dict[str, str]
    shards: tuple[str, ...]
    indexed_keys: int


PINNED_POLICY = SourcePolicy(
    SOURCE_REPO,
    SOURCE_REVISION,
    METADATA_PINS,
    tuple(f"model-{i:05d}-of-00131.safetensors" for i in range(1, 132)),
    1658,
)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def _download_metadata(source: Path, name: str) -> tuple[str | None, str | None]:
    path = source / ".cache" / "huggingface" / "download" / f"{name}.metadata"
    if not path.is_file():
        return None, None
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError):
        return None, None
    return (
        lines[0].strip() if lines else None,
        lines[1].strip() if len(lines) >= 2 else None,
    )


def verify_source(
    source: Path,
    *,
    hash_shards: bool = False,
    require_shards: bool = True,
    policy: SourcePolicy = PINNED_POLICY,
) -> dict[str, Any]:
    """Fail closed on missing identity or digest coverage.

    With hash_shards=False, success means metadata/inventory checks only.
    The policy argument supports synthetic unit fixtures; CLIs use the fixed
    pinned policy and expose no option to substitute another pin.
    """
    errors: list[str] = []
    missing: list[str] = []
    missing_hashes: list[str] = []
    invalid_hashes: list[str] = []
    revision_mismatch: list[str] = []
    pin_mismatch: list[dict[str, str]] = []
    shard_mismatch: list[dict[str, str]] = []
    observed_metadata: dict[str, str] = {}
    shards: list[dict[str, Any]] = []
    indexed_keys = 0
    marker_path = source / ".download-complete"
    try:
        marker = json.loads(marker_path.read_text())
        if not isinstance(marker, dict) or marker.get("repo") != policy.repo or marker.get("revision") != policy.revision:
            errors.append("download marker repository/revision mismatch")
    except (OSError, ValueError):
        errors.append("missing or invalid download marker")

    for name, expected in policy.metadata_pins.items():
        path = source / name
        if not path.is_file():
            pin_mismatch.append({"file": name, "error": "missing"})
            continue
        actual = sha256_file(path)
        observed_metadata[name] = actual
        if actual != expected:
            pin_mismatch.append({"file": name, "expected": expected, "actual": actual})
        revision, _ = _download_metadata(source, name)
        if revision != policy.revision:
            revision_mismatch.append(name)

    try:
        index = json.loads((source / "model.safetensors.index.json").read_text())
        weight_map = index["weight_map"]
        if not isinstance(weight_map, dict) or not all(isinstance(v, str) for v in weight_map.values()):
            raise ValueError("invalid weight_map")
        indexed_keys = len(weight_map)
        if indexed_keys != policy.indexed_keys:
            errors.append("source indexed key count differs from pin")
        if set(weight_map.values()) != set(policy.shards):
            errors.append("source shard names/count differ from pin")
    except (OSError, ValueError, KeyError, TypeError):
        errors.append("missing or invalid source index")

    for name in policy.shards:
        path = source / name
        present = path.is_file()
        if not present:
            missing.append(name)
        revision, expected = _download_metadata(source, name)
        if revision != policy.revision:
            revision_mismatch.append(name)
        if expected is None:
            missing_hashes.append(name)
        elif not SHA256_RE.fullmatch(expected):
            invalid_hashes.append(name)
        shards.append({
            "file": name,
            "bytes": path.stat().st_size if present else None,
            "expected_sha256": expected,
            "sha256": None,
        })

    if pin_mismatch:
        errors.append("pinned metadata missing or hash mismatch")
    if revision_mismatch:
        errors.append("cached metadata revision missing or mismatched")
    if missing_hashes or invalid_hashes:
        errors.append("incomplete valid source shard SHA-256 coverage")
    if missing and (require_shards or hash_shards):
        errors.append("missing source shards")

    checked = 0
    if hash_shards and not errors:
        for item in shards:
            actual = sha256_file(source / item["file"])
            item["sha256"] = actual
            checked += 1
            if actual != item["expected_sha256"]:
                shard_mismatch.append({"file": item["file"], "expected": item["expected_sha256"], "actual": actual})
    if shard_mismatch:
        errors.append("source shard payload hash mismatch")
    if hash_shards and checked != len(policy.shards):
        errors.append("full source shard hashing did not complete")

    return {
        "ok": not errors,
        "errors": errors,
        "repo": policy.repo,
        "revision": policy.revision,
        "dest": str(source),
        "verification_level": "full-shard-sha256" if hash_shards else "metadata-and-inventory",
        "source_payloads_verified": hash_shards and not errors and checked == len(policy.shards),
        "indexed_keys": indexed_keys,
        "shard_files": len(policy.shards),
        "present_shards": len(policy.shards) - len(missing),
        "missing_shards": missing,
        "pin_mismatch": pin_mismatch,
        "revision_mismatch": revision_mismatch,
        "missing_shard_hash_metadata": missing_hashes,
        "invalid_shard_hash_metadata": invalid_hashes,
        "shard_hash_expected": len(policy.shards),
        "shard_hash_metadata_count": len(policy.shards) - len(missing_hashes) - len(invalid_hashes),
        "shard_hash_checked": checked,
        "shard_mismatch": shard_mismatch,
        "hashed_shards": hash_shards,
        "marker": marker_path.is_file(),
        "metadata_sha256": observed_metadata,
        "source_shards": shards,
    }


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


def make_shard_manifest(source_evidence: dict[str, Any], outputs: list[dict[str, Any]]) -> dict[str, Any]:
    sources = source_evidence["source_shards"]
    source_names = {item["file"] for item in sources}
    output_names = {item["file"] for item in outputs}
    expected = source_evidence["shard_hash_expected"]
    if not source_evidence["ok"] or len(sources) != expected or len(source_names) != expected:
        raise ValueError("incomplete or invalid source evidence")
    if output_names != source_names or len(outputs) != expected:
        raise ValueError("incomplete or duplicate output digest coverage")
    for item in sources:
        digest = item.get("sha256")
        if not isinstance(digest, str) or not SHA256_RE.fullmatch(digest) or digest != item.get("expected_sha256"):
            raise ValueError("unverified source digest")
    for item in outputs:
        digest = item.get("sha256")
        if not isinstance(digest, str) or not SHA256_RE.fullmatch(digest):
            raise ValueError("invalid output digest")
        if not isinstance(item.get("bytes"), int) or item["bytes"] < 0:
            raise ValueError("invalid output byte count")
    return {
        "schema_version": 1,
        "algorithm": "sha256",
        "source_repo": source_evidence["repo"],
        "source_revision": source_evidence["revision"],
        "source_metadata_sha256": source_evidence["metadata_sha256"],
        "source_payloads_verified": True,
        "source_shards": sorted(sources, key=lambda item: item["file"]),
        "output_shards": sorted(outputs, key=lambda item: item["file"]),
    }
