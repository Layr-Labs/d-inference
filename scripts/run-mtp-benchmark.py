#!/usr/bin/env python3
"""Run cache-only MTP live tests under a hard process-group deadline."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import secrets
import signal
import stat
import subprocess
import sys
import tempfile
import time
from typing import Any


REPO_ROOT = Path(__file__).resolve().parent.parent
PACKAGE_ROOT = REPO_ROOT / "provider-swift"
DEFAULT_TARGET_ID = "mlx-community/gemma-4-26B-A4B-it-qat-4bit"
DEFAULT_ASSISTANT_ID = "mlx-community/gemma-4-26B-A4B-it-qat-assistant-4bit"
DEFAULT_TEST_FILTER = "GemmaMTPPerformanceLiveTests"
REPORT_SCHEMA_VERSION = 5
REPORT_NAME = "report.json"
LOG_NAME = "benchmark.log"
SUPERVISOR_CONTRACT = "run-mtp-benchmark-v1"
LEGACY_M5_INACTIVE_REASON_PREFIX = (
    "rectangular MTP verification is disabled on Apple M5"
)
MAX_CACHE_ROOTS = 8
MAX_FALLBACK_REPOSITORY_ENTRIES = 4096
MAX_FALLBACK_REPOSITORIES = 8
MAX_SNAPSHOT_ENTRIES = 512
MAX_REF_BYTES = 256
MAX_REPORT_BYTES = 100 * 1024 * 1024
PERFORMANCE_KEYS = {
    "elapsedMs",
    "medianAggregateDecodeTokensPerSecond",
    "timeToFirstTokenMs",
    "interTokenLatencyMs",
    "decodeTokensPerSecond",
    "lastTokenLatencyMs",
    "ewmaRoundWallTimeNanos",
    "totalRoundWallTimeNanos",
    "assistantTimeNanos",
    "targetVerifyTimeNanos",
}
HEX_DIGITS = frozenset("0123456789abcdef")


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
    config_digest = sha256_file(config)
    # Independently parse the coverage-relevant metadata from the SAME bytes
    # that were hashed, so the supervisor's coverage gates do not depend
    # solely on the Swift inspector's transcription of these fields.
    with open(config, "rb") as handle:
        parsed = json.loads(read_bounded(handle.fileno(), 4 * 1024 * 1024))
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


def open_directory(path: Path) -> int:
    return os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)


class SecureRunDirectory:
    def __init__(
        self,
        *,
        root_fd: int,
        directory_fd: int,
        path: Path,
        device: int,
        inode: int,
    ) -> None:
        self.root_fd = root_fd
        self.directory_fd = directory_fd
        self.path = path
        self.device = device
        self.inode = inode

    @classmethod
    def create(cls, requested: Path) -> "SecureRunDirectory":
        expanded = requested.expanduser()
        absolute = expanded if expanded.is_absolute() else Path.cwd() / expanded
        lexical = Path(os.path.abspath(absolute))
        repo_tmp = Path(os.path.abspath(REPO_ROOT / "tmp"))
        system_tmp = Path(os.path.abspath(tempfile.gettempdir()))
        if lexical == repo_tmp or repo_tmp in lexical.parents:
            if not repo_tmp.exists():
                repo_tmp.mkdir(mode=0o700)
            if not stat.S_ISDIR(repo_tmp.lstat().st_mode):
                raise SystemExit(f"repo temp root is not a real directory: {repo_tmp}")
            selected = repo_tmp
        elif lexical == system_tmp or system_tmp in lexical.parents:
            selected = system_tmp
        else:
            raise SystemExit(
                f"refusing tracked result path {lexical}; use {repo_tmp} or {system_tmp}"
            )

        resolved_root = selected.resolve(strict=True)
        root_fd = open_directory(resolved_root)
        root_metadata = os.fstat(root_fd)
        if not stat.S_ISDIR(root_metadata.st_mode):
            os.close(root_fd)
            raise SystemExit(f"approved output root is not a directory: {resolved_root}")

        stem = "".join(
            character if character.isalnum() or character in "-_" else "-"
            for character in lexical.stem
        )[:48] or "mtp"
        timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        for _ in range(32):
            name = f"{stem}-{timestamp}-{secrets.token_hex(8)}.run"
            try:
                os.mkdir(name, mode=0o700, dir_fd=root_fd)
            except FileExistsError:
                continue
            directory_fd = os.open(
                name,
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                dir_fd=root_fd,
            )
            metadata = os.fstat(directory_fd)
            if not stat.S_ISDIR(metadata.st_mode) or stat.S_IMODE(metadata.st_mode) != 0o700:
                os.close(directory_fd)
                os.close(root_fd)
                raise SystemExit("new benchmark run directory is not private")
            return cls(
                root_fd=root_fd,
                directory_fd=directory_fd,
                path=resolved_root / name,
                device=metadata.st_dev,
                inode=metadata.st_ino,
            )
        os.close(root_fd)
        raise SystemExit("could not allocate a unique benchmark run directory")

    @classmethod
    def reopen(
        cls,
        path: Path,
        expected_device: int,
        expected_inode: int,
    ) -> "SecureRunDirectory":
        directory_fd = open_directory(path)
        metadata = os.fstat(directory_fd)
        if (
            not stat.S_ISDIR(metadata.st_mode)
            or metadata.st_dev != expected_device
            or metadata.st_ino != expected_inode
        ):
            os.close(directory_fd)
            raise SystemExit("benchmark run directory identity changed")
        return cls(
            root_fd=-1,
            directory_fd=directory_fd,
            path=path,
            device=metadata.st_dev,
            inode=metadata.st_ino,
        )

    def create_file(self, name: str) -> int:
        validate_leaf_name(name)
        return os.open(
            name,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
            0o600,
            dir_fd=self.directory_fd,
        )

    def atomic_write(self, name: str, data: bytes) -> None:
        validate_leaf_name(name)
        temporary = f".{name}.{secrets.token_hex(8)}.tmp"
        descriptor = self.create_file(temporary)
        try:
            write_all(descriptor, data)
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
        try:
            os.replace(
                temporary,
                name,
                src_dir_fd=self.directory_fd,
                dst_dir_fd=self.directory_fd,
            )
            os.fsync(self.directory_fd)
        finally:
            try:
                os.unlink(temporary, dir_fd=self.directory_fd)
            except FileNotFoundError:
                # os.replace already moved the temp file into place, so
                # best-effort cleanup finding nothing is the success case.
                pass

    def read_regular(self, name: str, maximum_bytes: int) -> tuple[bytes, os.stat_result]:
        validate_leaf_name(name)
        descriptor = os.open(
            name,
            os.O_RDONLY | os.O_NOFOLLOW,
            dir_fd=self.directory_fd,
        )
        try:
            metadata = os.fstat(descriptor)
            if not stat.S_ISREG(metadata.st_mode):
                raise ValueError(f"{name} is not a regular file")
            if metadata.st_size <= 0 or metadata.st_size > maximum_bytes:
                raise ValueError(f"{name} size is invalid: {metadata.st_size}")
            data = read_bounded(descriptor, maximum_bytes)
            return data, metadata
        finally:
            os.close(descriptor)

    def visible_identity_matches(self) -> bool:
        try:
            metadata = self.path.lstat()
        except OSError:
            return False
        return (
            stat.S_ISDIR(metadata.st_mode)
            and metadata.st_dev == self.device
            and metadata.st_ino == self.inode
        )

    def close(self) -> None:
        if self.directory_fd >= 0:
            os.close(self.directory_fd)
            self.directory_fd = -1
        if self.root_fd >= 0:
            os.close(self.root_fd)
            self.root_fd = -1


def validate_leaf_name(name: str) -> None:
    if not name or name in {".", ".."} or "/" in name:
        raise ValueError(f"invalid run-directory filename: {name!r}")


def write_all(descriptor: int, data: bytes) -> None:
    view = memoryview(data)
    while view:
        written = os.write(descriptor, view)
        if written <= 0:
            raise OSError("short descriptor-relative write")
        view = view[written:]


def read_bounded(descriptor: int, maximum_bytes: int) -> bytes:
    chunks: list[bytes] = []
    remaining = maximum_bytes + 1
    while remaining > 0:
        chunk = os.read(descriptor, min(1024 * 1024, remaining))
        if not chunk:
            break
        chunks.append(chunk)
        remaining -= len(chunk)
    data = b"".join(chunks)
    if len(data) > maximum_bytes:
        raise ValueError(f"file exceeds {maximum_bytes} bytes")
    return data


def terminate_group(process: subprocess.Popen[Any]) -> None:
    """Terminate the supervised session and always reap the direct child."""

    def signal_supervised(sig: int) -> None:
        # Always try the GROUP first, even when the direct worker has already
        # exited: a crashed worker can leave its `swift test` descendants
        # alive in the supervised group, and the pgid stays valid while any
        # member lives. Returning early on poll() would skip both the SIGTERM
        # and the SIGKILL and orphan a live MLX benchmark.
        try:
            os.killpg(process.pid, sig)
            return
        except ProcessLookupError:
            # The whole group is gone.
            return
        except PermissionError:
            # Sandboxed macOS sessions can deny process-group signalling even
            # though the direct child remains ours. Fall back to that child;
            # its own cleanup owns any descendants.
            if process.poll() is not None:
                return
            try:
                process.send_signal(sig)
            except (ProcessLookupError, PermissionError):
                return

    def group_exists() -> bool:
        try:
            os.killpg(process.pid, 0)
            return True
        except ProcessLookupError:
            return False
        except PermissionError:
            return process.poll() is None

    deadline = time.monotonic() + 10
    signal_supervised(signal.SIGTERM)
    while group_exists() and time.monotonic() < deadline:
        process.poll()
        time.sleep(0.05)
    if group_exists():
        signal_supervised(signal.SIGKILL)
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        signal_supervised(signal.SIGKILL)
        process.wait()


def parse_timestamp(value: Any, field: str) -> datetime:
    if not isinstance(value, str):
        raise ValueError(f"{field} must be an ISO-8601 string")
    normalized = value[:-1] + "+00:00" if value.endswith("Z") else value
    parsed = datetime.fromisoformat(normalized)
    if parsed.tzinfo is None:
        raise ValueError(f"{field} must include a timezone")
    return parsed.astimezone(timezone.utc)


def observed_bucket(metrics: dict[str, Any], expected: int) -> bool:
    if metrics.get("decodeRowBucket") == expected:
        return True
    return any(
        isinstance(item, dict) and item.get("decodeRowBucket") == expected
        for item in metrics.get("costInputs", [])
    )


def expected_mtp_expectation(expect_inactive: bool) -> dict[str, Any]:
    return {
        "kind": "expected_inactive" if expect_inactive else "active",
        "allowedInactiveReasonValues": [],
        "allowedInactiveReasonPrefixes": (
            [LEGACY_M5_INACTIVE_REASON_PREFIX] if expect_inactive else []
        ),
    }


def inactive_reason_matches(
    metrics: dict[str, Any], expectation: dict[str, Any]
) -> bool:
    reason = metrics.get("inactiveReason")
    if not isinstance(reason, str) or not reason:
        return False
    return reason in expectation["allowedInactiveReasonValues"] or any(
        reason.startswith(prefix)
        for prefix in expectation["allowedInactiveReasonPrefixes"]
    )


def validate_zero_speculative_work(metrics: dict[str, Any], label: str) -> None:
    for field in (
        "rounds",
        "seedRows",
        "proposedTokens",
        "acceptedDraftTokens",
        "committedTokens",
    ):
        if metrics.get(field) != 0:
            raise ValueError(f"{label} reported speculative work in {field}")
    # Target verification with zero claimed rounds is still speculative work.
    # These counters are optional in the schema (inactive metrics omit them),
    # so absence counts as zero.
    for field in (
        "rectangularVerificationRounds",
        "serialVerificationRounds",
    ):
        if metrics.get(field) not in (None, 0):
            raise ValueError(f"{label} reported speculative work in {field}")
    for field in (
        "acceptanceByPosition",
        "conditionalAcceptance",
        "skippedRows",
        "depthSelections",
        "controllerFallbacks",
        "costInputs",
    ):
        if metrics.get(field) not in ([], {}):
            raise ValueError(f"{label} reported speculative work in {field}")
    for field in (
        "totalRoundWallTimeNanos",
        "assistantTimeNanos",
        "targetVerifyTimeNanos",
    ):
        if metrics.get(field) is not None:
            raise ValueError(f"{label} reported speculative timing in {field}")


def automatic_rectangular_cap(metrics: dict[str, Any]) -> int | None:
    if metrics.get("verificationMode") != "automatic":
        return None
    cap = metrics.get("maxAutomaticRectangularTokens")
    if isinstance(cap, int) and not isinstance(cap, bool) and cap >= 0:
        return cap
    return None


def positive_cost_inputs(metrics: dict[str, Any]) -> list[dict[str, Any]]:
    return [
        item
        for item in metrics.get("costInputs", [])
        if isinstance(item, dict)
        and item.get("draftDepth", 0) > 0
        and item.get("sampleCount", 0) > 0
    ]


def positive_costs_within_cap(metrics: dict[str, Any], cap: int) -> bool:
    return all(
        item.get("decodeRowBucket", 0) * (item.get("draftDepth", 0) + 1) <= cap
        for item in positive_cost_inputs(metrics)
    )


def validate_automatic_fixed_fallback(
    metrics: dict[str, Any], batch: int, depth: int, label: str
) -> bool:
    """Mirror MTPBenchmarkRunner.validateAutomaticDepthLimitFallback.

    A fixed depth whose batch * (1 + k) exceeds the automatic cap is clamped
    before seed/draft work: either to a smaller positive depth (rectangular
    rounds without controller cost samples, because cost attribution rejects
    depth-mismatched work) or to certified zero-work target-only chaining.
    """
    cap = automatic_rectangular_cap(metrics)
    if cap is None or batch * (depth + 1) <= cap:
        return False
    selections = metrics.get("depthSelections", {})
    has_positive_depth = any(
        key.isdigit() and int(key) > 0 and count > 0
        for key, count in selections.items()
        if isinstance(key, str) and isinstance(count, int)
    )
    if (
        metrics.get("controllerFallbacks", {}).get("automatic_rectangular_limit", 0) <= 0
        or not positive_costs_within_cap(metrics, cap)
        or metrics.get("serialVerificationRounds", 0) != 0
    ):
        raise ValueError(f"{label} escaped its rectangular limit")
    if has_positive_depth:
        if (
            metrics.get("rounds", 0) <= 0
            or metrics.get("proposedTokens", 0) <= 0
            or metrics.get("rectangularVerificationRounds", 0) <= 0
        ):
            raise ValueError(f"{label} lacks clamped-depth evidence")
        return True
    if (
        metrics.get("selectedDepth") != 0
        or selections.get("0", 0) <= 0
        or metrics.get("rounds", 0) != 0
        or metrics.get("seedRows", 0) != 0
        or metrics.get("proposedTokens", 0) != 0
        or metrics.get("acceptedDraftTokens", 0) != 0
        or metrics.get("committedTokens", 0) != 0
        or metrics.get("rectangularVerificationRounds", 0) != 0
        or metrics.get("costInputs") not in ([], None)
    ):
        raise ValueError(f"{label} reported uncategorized work")
    return True


def validate_automatic_adaptive_within_cap(
    metrics: dict[str, Any], batch: int, label: str
) -> bool:
    """Adaptive drafting cannot be demanded when even depth one exceeds the
    automatic cap at this batch size; any drafting after tail rows drain must
    stay rectangular and inside the cap."""
    cap = automatic_rectangular_cap(metrics)
    if cap is None or batch * 2 <= cap:
        return False
    if (
        not positive_costs_within_cap(metrics, cap)
        or metrics.get("serialVerificationRounds", 0) not in (None, 0)
    ):
        raise ValueError(f"{label} escaped its automatic rectangular limit")
    rounds = metrics.get("rounds", 0)
    if rounds > 0:
        # Drafting after tail rows drained inside the cap: every row-round
        # proposes at least one token and is scored by at least one
        # rectangular batch verification (rounds count per-row finalizes;
        # verifier counters count per-batch passes, so equality is NOT the
        # invariant here).
        if (
            metrics.get("proposedTokens", 0) <= 0
            or (metrics.get("rectangularVerificationRounds") or 0) <= 0
        ):
            raise ValueError(
                f"{label} drafted without rectangular verification evidence")
        return True
    # Zero rounds: nothing may have been proposed, accepted, committed, or
    # verified. Seed steps alone remain legitimate — they are recorded at
    # step launch and a seed's row can terminate before its round runs.
    if (
        metrics.get("proposedTokens", 0) != 0
        or metrics.get("acceptedDraftTokens", 0) != 0
        or metrics.get("committedTokens", 0) != 0
        or metrics.get("rectangularVerificationRounds", 0) not in (None, 0)
        or any(count != 0 for count in metrics.get("acceptanceByPosition", []))
        or any(
            item.get("draftDepth", 0) != 0
            for item in metrics.get("costInputs", [])
            if isinstance(item, dict)
        )
    ):
        raise ValueError(f"{label} reported speculative counters without rounds")
    return True


def recursively_present_keys(value: Any, wanted: set[str]) -> set[str]:
    found: set[str] = set()
    if isinstance(value, dict):
        for key, child in value.items():
            if key in wanted:
                found.add(key)
            found.update(recursively_present_keys(child, wanted))
    elif isinstance(value, list):
        for child in value:
            found.update(recursively_present_keys(child, wanted))
    return found


def effective_quantization_bits(artifact: dict[str, Any]) -> int | None:
    quantization = artifact.get("quantization")
    if not isinstance(quantization, dict):
        return None
    bits = quantization.get("bits")
    if isinstance(bits, int) and not isinstance(bits, bool):
        return bits
    overrides = quantization.get("perLayerOverridesByBits", {})
    if not isinstance(overrides, dict):
        return None
    values = {
        int(key)
        for key, count in overrides.items()
        if isinstance(key, str)
        and key.isdigit()
        and isinstance(count, int)
        and count > 0
    }
    return next(iter(values)) if len(values) == 1 else None


def expected_coverage(report: dict[str, Any]) -> dict[str, str]:
    target = report.get("target", {})
    assistant = report.get("assistant", {})
    target_name = str(target.get("modelID", "")).lower()
    assistant_name = str(assistant.get("modelID", "")).lower()
    qat4 = (
        "qat" in target_name
        and "qat" in assistant_name
        and effective_quantization_bits(target) == 4
        and effective_quantization_bits(assistant) == 4
    )
    # Both official Gemma 4 target config types count: multimodal checkpoints
    # report "gemma4" and text-only checkpoints report "gemma4_text" (mirrors
    # MTPBenchmarkCoverage.shortContextMatrix).
    eight_bit_target = (
        target.get("modelType") in ("gemma4", "gemma4_text")
        and effective_quantization_bits(target) == 8
    )
    assistant_dtype = str(assistant.get("dtype", "")).lower().replace("_", "").replace("-", "")
    bf16_assistant = (
        assistant.get("modelType") == "gemma4_assistant"
        and assistant_dtype in {"bfloat16", "bf16"}
        and assistant.get("quantization") is None
    )
    return {
        "qat4BitShortContextSmoke": "covered" if qat4 else "not_run",
        "eightBitTargetPairing": "covered" if eight_bit_target else "not_run",
        "bf16AssistantPairing": "covered" if bf16_assistant else "not_run",
        "officialTensorFixtures": "not_implemented",
        # The short cached-model matrix never exercises tool templates or
        # image prefill; a report claiming either as covered must fail.
        "toolTemplateDecodeParity": "not_in_this_report",
        "structuredOutput": "not_implemented",
        "imagePrefill": "not_in_this_report",
        "videoPrefill": "not_implemented",
        "longSlidingAndPrefixContexts": "not_implemented",
        "opaqueTokenEvidence": "covered",
        "productionServingStopPolicy": (
            "not_in_this_report"
            if report.get("purpose") == "raw_parity_stress"
            else "covered"
        ),
        "artifactProvenanceAndDrift": "covered",
        "conservativeAssistantSizing": "covered",
    }


def validate_report_artifact(
    report_artifact: Any,
    expected: dict[str, Any],
    label: str,
) -> None:
    if not isinstance(report_artifact, dict):
        raise ValueError(f"report {label} artifact is not an object")
    for key in (
        "modelID",
        "resolvedPath",
        "revision",
        "configSizeBytes",
        "configSHA256",
        "weightFiles",
        "artifactFingerprint",
    ):
        if report_artifact.get(key) != expected[key]:
            raise ValueError(f"report {label} {key} does not match launch provenance")
    # Anchor the coverage-relevant metadata to the launch-side parse of the
    # SAME hashed config bytes: a regressed Swift inspector must not be able
    # to claim false QAT/8-bit/BF16 coverage while fingerprints still match.
    metadata = expected.get("configMetadata") or {}
    if report_artifact.get("modelType") != metadata.get("model_type"):
        raise ValueError(f"report {label} modelType does not match launch config.json")
    # Strict TWO-WAY equality: a report may neither invent a dtype the hashed
    # config lacks nor drop/alter one it has — BF16 coverage keys on this.
    if report_artifact.get("dtype") != metadata.get("dtype"):
        raise ValueError(f"report {label} dtype does not match launch config.json")
    if bool(metadata.get("has_quantization")) != (report_artifact.get("quantization") is not None):
        raise ValueError(f"report {label} quantization presence does not match launch config.json")
    # Compare the EFFECTIVE bits the coverage gate consumes (top-level or
    # unique per-layer override), so override-only configs are anchored too.
    if effective_quantization_bits(report_artifact) != metadata.get("effective_quantization_bits"):
        raise ValueError(f"report {label} quantization bits do not match launch config.json")


def validate_report(
    run: SecureRunDirectory,
    *,
    fingerprint: str,
    launch_time: float,
    mode: str,
    build_configuration: str,
    target: dict[str, Any],
    assistant: dict[str, Any],
    max_tokens: int,
    warmup: int,
    repetitions: int,
    seed: int,
    expect_mtp_inactive: bool,
) -> None:
    encoded, metadata = run.read_regular(REPORT_NAME, MAX_REPORT_BYTES)
    if metadata.st_mtime < launch_time - 1:
        raise ValueError("report mtime predates this launch")
    report = json.loads(encoded.decode("utf-8"))
    if not isinstance(report, dict):
        raise ValueError("report root is not an object")
    if report.get("schemaVersion") != REPORT_SCHEMA_VERSION:
        raise ValueError(
            f"schemaVersion is {report.get('schemaVersion')}, expected {REPORT_SCHEMA_VERSION}"
        )
    expectation = expected_mtp_expectation(expect_mtp_inactive)
    expected_fingerprint = (
        f"{build_configuration}:{expectation['kind']}:{fingerprint}"
    )
    if report.get("runFingerprint") != expected_fingerprint:
        raise ValueError("run fingerprint does not match this launch")
    if report.get("buildConfiguration") != build_configuration:
        raise ValueError("report build configuration does not match this launch")
    if report.get("mtpExpectation") != expectation:
        raise ValueError("report MTP expectation does not match this launch")
    if mode == "production-performance" and expect_mtp_inactive:
        raise ValueError("production performance cannot be expected-inactive")
    if report.get("complete") is not True:
        raise ValueError("report is only a partial checkpoint")
    if report.get("expectedCaseCount") != 40:
        raise ValueError("expectedCaseCount is not 40")
    if report.get("maxTokensPerRow") != max_tokens:
        raise ValueError("maxTokensPerRow does not match the request")
    if report.get("warmupIterations") != warmup:
        raise ValueError("warmupIterations does not match the request")
    if report.get("measurementRepetitions") != repetitions:
        raise ValueError("measurementRepetitions does not match the request")
    if report.get("modeOrderSeed") != seed:
        raise ValueError("modeOrderSeed does not match the request")
    validate_report_artifact(report.get("target"), target, "target")
    validate_report_artifact(report.get("assistant"), assistant, "assistant")

    expected_purpose = (
        "raw_parity_stress" if mode == "raw-parity" else "production_performance"
    )
    expected_stop = (
        "raw_fixed_length_no_stop"
        if mode == "raw-parity"
        else "production_target_eos"
    )
    if report.get("purpose") != expected_purpose:
        raise ValueError("report purpose does not match this launch")
    stop_policy = report.get("stopPolicy", {})
    if stop_policy.get("kind") != expected_stop:
        raise ValueError("report stop policy does not match this launch")
    configured_stop_count = stop_policy.get("configuredTokenCount")
    if mode == "raw-parity" and configured_stop_count != 0:
        raise ValueError("raw parity report claims configured stop tokens")
    if mode == "production-performance" and (
        not isinstance(configured_stop_count, int) or configured_stop_count <= 0
    ):
        raise ValueError("production performance report has no target EOS evidence")
    exposed_token_arrays = recursively_present_keys(report, {"tokenIDs"})
    if exposed_token_arrays:
        raise ValueError("report recursively exposes raw token IDs")
    if mode != "production-performance":
        exposed = recursively_present_keys(report, PERFORMANCE_KEYS)
        if exposed:
            raise ValueError(
                f"non-performance report recursively exposes performance keys: {sorted(exposed)}"
            )
    elif not isinstance(report.get("elapsedMs"), (int, float)):
        raise ValueError("production performance report omitted elapsedMs")

    started_at = parse_timestamp(report.get("startedAt"), "startedAt")
    generated_at = parse_timestamp(report.get("generatedAt"), "generatedAt")
    completed_at = parse_timestamp(report.get("completedAt"), "completedAt")
    launch_datetime = datetime.fromtimestamp(launch_time, timezone.utc)
    now = datetime.now(timezone.utc)
    if started_at < launch_datetime.replace(microsecond=0):
        raise ValueError("report startedAt predates this launch")
    if not (started_at <= generated_at <= now) or not (started_at <= completed_at <= now):
        raise ValueError("report timestamps are not fresh and ordered")

    cases = report.get("cases")
    if not isinstance(cases, list) or len(cases) != 40:
        count = len(cases) if isinstance(cases, list) else "invalid"
        raise ValueError(f"report has {count} cases")
    expected_keys = {
        (kind, width, batch)
        for kind, widths in (
            ("target_only", [None]),
            ("fixed", list(range(1, 9))),
            ("adaptive", [None]),
        )
        for width in widths
        for batch in (1, 2, 4, 8)
    }
    actual_keys: set[tuple[str, int | None, int]] = set()
    baseline_rows: dict[int, list[tuple[str, int, str]]] = {}
    for case in cases:
        if not isinstance(case, dict):
            raise ValueError("case is not an object")
        mode_value = case.get("mode", {})
        kind = mode_value.get("kind")
        width = mode_value.get("verificationWidth")
        batch = case.get("batchSize")
        actual_keys.add((kind, width, batch))
        if case.get("measurementRepetitions") != repetitions:
            raise ValueError(f"case {kind}/{width}/B{batch} repetition count is wrong")
        if case.get("tokenParity") is not True or case.get("parityMismatchRows") != []:
            raise ValueError(f"case {kind}/{width}/B{batch} failed token parity")
        rows = case.get("rows", [])
        if not isinstance(rows, list) or len(rows) != batch:
            raise ValueError(f"case {kind}/{width}/B{batch} has the wrong row count")
        row_evidence: list[tuple[str, int, str]] = []
        for row_index, row in enumerate(rows):
            if not isinstance(row, dict):
                raise ValueError(f"case {kind}/{width}/B{batch} row {row_index} is invalid")
            token_count = row.get("tokenCount")
            digest = row.get("opaqueTokenDigest")
            if not isinstance(token_count, int) or token_count <= 0:
                raise ValueError(f"case {kind}/{width}/B{batch} row {row_index} has no token count")
            if (
                not isinstance(digest, str)
                or len(digest) != 64
                or set(digest.lower()) - HEX_DIGITS
            ):
                raise ValueError(f"case {kind}/{width}/B{batch} row {row_index} has invalid opaque evidence")
            if mode == "raw-parity" and (
                row.get("finishReason") != "length" or token_count != max_tokens
            ):
                raise ValueError(f"case {kind}/{width}/B{batch} row {row_index} is not fixed length")
            if mode != "raw-parity" and row.get("finishReason") not in {"stop", "length"}:
                raise ValueError(f"case {kind}/{width}/B{batch} row {row_index} has invalid terminal reason")
            if (
                mode != "raw-parity"
                and row.get("finishReason") == "length"
                and token_count != max_tokens
            ):
                raise ValueError(f"case {kind}/{width}/B{batch} row {row_index} length terminal is premature")
            if (
                mode != "raw-parity"
                and row.get("finishReason") == "stop"
                and token_count > max_tokens
            ):
                raise ValueError(f"case {kind}/{width}/B{batch} row {row_index} stop terminal exceeds maxTokens")
            # finishReason is part of the cross-mode evidence: identical
            # tokens with a different terminal reason (EOS at the budget as
            # "stop" vs "length") is an OpenAI-visible divergence.
            row_evidence.append(
                (str(row.get("promptName", "")), token_count, digest,
                 str(row.get("finishReason", ""))))
        if kind == "target_only":
            baseline_rows[batch] = row_evidence
        elif baseline_rows.get(batch) != row_evidence:
            raise ValueError(f"case {kind}/{width}/B{batch} opaque evidence differs from baseline")
        if mode != "raw-parity":
            if case.get("medianAggregateDecodeTokensPerSecond") is None:
                raise ValueError("production performance case omitted aggregate throughput")

        metrics = case.get("metrics", {})
        expected_bucket = batch
        skipped = metrics.get("skippedRows", {})
        if skipped:
            raise ValueError(f"case {kind}/{width}/B{batch} reported unapproved skips: {skipped}")
        if kind == "target_only":
            if metrics.get("active") is not False:
                raise ValueError(f"target-only B{batch} reported MTP active")
            validate_zero_speculative_work(metrics, f"target-only B{batch}")
        elif kind == "fixed":
            if expect_mtp_inactive:
                if metrics.get("active") is not False:
                    raise ValueError(
                        f"fixed L{width}/B{batch} unexpectedly reported MTP active"
                    )
                if not inactive_reason_matches(metrics, expectation):
                    raise ValueError(
                        f"fixed L{width}/B{batch} inactive reason is not allowed"
                    )
                validate_zero_speculative_work(
                    metrics, f"fixed L{width}/B{batch} expected-inactive"
                )
                continue
            if metrics.get("active") is not True:
                raise ValueError(f"fixed L{width}/B{batch} did not prove activation")
            depth = width - 1
            if validate_automatic_fixed_fallback(
                metrics, batch, depth, f"fixed L{width}/B{batch}"
            ):
                continue
            if not observed_bucket(metrics, expected_bucket):
                raise ValueError(f"fixed L{width}/B{batch} did not prove its bucket")
            if metrics.get("depthSelections", {}).get(str(depth), 0) <= 0:
                raise ValueError(f"fixed L{width}/B{batch} never selected depth {depth}")
            if depth > 0:
                if metrics.get("rounds", 0) <= 0 or metrics.get("proposedTokens", 0) <= 0:
                    raise ValueError(f"fixed L{width}/B{batch} did not draft")
                if not any(
                    item.get("decodeRowBucket") == expected_bucket
                    and item.get("draftDepth") == depth
                    and item.get("sampleCount", 0) > 0
                    for item in metrics.get("costInputs", [])
                    if isinstance(item, dict)
                ):
                    raise ValueError(f"fixed L{width}/B{batch} lacks depth/bucket cost evidence")
        elif kind == "adaptive":
            if expect_mtp_inactive:
                if metrics.get("active") is not False:
                    raise ValueError(
                        f"adaptive B{batch} unexpectedly reported MTP active"
                    )
                if not inactive_reason_matches(metrics, expectation):
                    raise ValueError(
                        f"adaptive B{batch} inactive reason is not allowed"
                    )
                validate_zero_speculative_work(
                    metrics, f"adaptive B{batch} expected-inactive"
                )
                continue
            if metrics.get("active") is not True or not observed_bucket(metrics, expected_bucket):
                raise ValueError(f"adaptive B{batch} did not prove activation/bucket")
            if validate_automatic_adaptive_within_cap(
                metrics, batch, f"adaptive B{batch}"
            ):
                continue
            if metrics.get("rounds", 0) <= 0 or metrics.get("proposedTokens", 0) <= 0:
                raise ValueError(f"adaptive B{batch} did not draft")
            if not any(
                int(depth) > 0 and count > 0
                for depth, count in metrics.get("depthSelections", {}).items()
            ):
                raise ValueError(f"adaptive B{batch} never selected nonzero depth")
            if not any(
                item.get("decodeRowBucket") == expected_bucket
                and item.get("draftDepth", 0) > 0
                and item.get("sampleCount", 0) > 0
                for item in metrics.get("costInputs", [])
                if isinstance(item, dict)
            ):
                raise ValueError(
                    f"adaptive B{batch} lacks positive-depth cost evidence for its requested bucket"
                )
    if actual_keys != expected_keys:
        missing = sorted(expected_keys - actual_keys, key=str)
        extra = sorted(actual_keys - expected_keys, key=str)
        raise ValueError(f"case set mismatch; missing={missing}, extra={extra}")

    coverage = report.get("coverage", {})
    for field, expected in expected_coverage(report).items():
        if coverage.get(field) != expected:
            raise ValueError(f"coverage.{field} is not dynamically labeled {expected}")


def fingerprint_for(
    args: argparse.Namespace,
    *,
    target_id: str,
    assistant_id: str,
    target: dict[str, Any],
    assistant: dict[str, Any],
    warmup: int,
    repetitions: int,
    build_configuration: str,
) -> str:
    payload = json.dumps(
        {
            "target_id": target_id,
            "assistant_id": assistant_id,
            "target_fingerprint": target["artifactFingerprint"],
            "assistant_fingerprint": assistant["artifactFingerprint"],
            "mode": args.mode,
            "mtp_expectation": expected_mtp_expectation(args.expect_mtp_inactive),
            "build_configuration": build_configuration,
            "test_filter": args.test_filter,
            "max_tokens": args.max_tokens,
            "warmup": warmup,
            "repetitions": repetitions,
            "seed": args.seed,
            "launch_ns": time.time_ns(),
            "nonce": secrets.token_hex(16),
        },
        sort_keys=True,
    ).encode()
    return hashlib.sha256(payload).hexdigest()


def worker_main(args: argparse.Namespace, warmup: int, repetitions: int) -> int:
    run = SecureRunDirectory.reopen(
        args._worker_run_directory,
        args._worker_run_device,
        args._worker_run_inode,
    )
    try:
        build_configuration = "debug" if args.debug else "release"
        target_id, target = resolve_model_snapshot(
            args.target_id, args.target_path, DEFAULT_TARGET_ID, "target"
        )
        assistant_id, assistant = resolve_model_snapshot(
            args.assistant_id, args.assistant_path, DEFAULT_ASSISTANT_ID, "assistant"
        )
        target_facts = artifact_facts(target_id, target)
        assistant_facts = artifact_facts(assistant_id, assistant)
        fingerprint = fingerprint_for(
            args,
            target_id=target_id,
            assistant_id=assistant_id,
            target=target_facts,
            assistant=assistant_facts,
            warmup=warmup,
            repetitions=repetitions,
            build_configuration=build_configuration,
        )
        launch_time = time.time()
        output = run.path / REPORT_NAME
        log_path = run.path / LOG_NAME

        environment = os.environ.copy()
        environment.update(
            {
                "DARKBLOOM_LIVE_MLX_TESTS": "1",
                "DARKBLOOM_LIVE_MLX_GEMMA": "1",
                "DARKBLOOM_LIVE_MLX_MTP": "1",
                "DARKBLOOM_MTP_EXTERNAL_SUPERVISOR": SUPERVISOR_CONTRACT,
                "DARKBLOOM_MTP_TARGET_ID": target_id,
                "DARKBLOOM_MTP_ASSISTANT_ID": assistant_id,
                "DARKBLOOM_MTP_TARGET_PATH": str(target),
                "DARKBLOOM_MTP_ASSISTANT_PATH": str(assistant),
                "DARKBLOOM_MTP_BENCHMARK_OUTPUT": str(output),
                "DARKBLOOM_MTP_BENCHMARK_RUN_DIRECTORY": str(run.path),
                "DARKBLOOM_MTP_BENCHMARK_RUN_DEVICE": str(run.device),
                "DARKBLOOM_MTP_BENCHMARK_RUN_INODE": str(run.inode),
                "DARKBLOOM_MTP_BENCHMARK_BUILD_CONFIGURATION": build_configuration,
                "DARKBLOOM_MTP_BENCHMARK_MAX_TOKENS": str(args.max_tokens),
                "DARKBLOOM_MTP_BENCHMARK_MODE": args.mode,
                "DARKBLOOM_MTP_BENCHMARK_EXPECT_MTP_INACTIVE": (
                    "1" if args.expect_mtp_inactive else "0"
                ),
                "DARKBLOOM_MTP_BENCHMARK_WARMUP": str(warmup),
                "DARKBLOOM_MTP_BENCHMARK_REPETITIONS": str(repetitions),
                "DARKBLOOM_MTP_BENCHMARK_SEED": str(args.seed),
                "DARKBLOOM_MTP_BENCHMARK_RUN_FINGERPRINT": fingerprint,
                "DARKBLOOM_MTP_BENCHMARK_DEADLINE_SECONDS": str(
                    max(1, args.timeout_seconds - 30)
                ),
                "HF_HUB_OFFLINE": "1",
                "TRANSFORMERS_OFFLINE": "1",
            }
        )
        command = [
            "swift",
            "test",
            "-c",
            build_configuration,
            "--filter",
            args.test_filter,
        ]
        print(f"target={target}")
        print(f"assistant={assistant}")
        print(f"run_directory={run.path}")
        print(f"result={output}")
        print(f"log={log_path}")
        print(f"mode={args.mode}")
        print(f"expect_mtp_inactive={args.expect_mtp_inactive}")
        print(f"build_configuration={build_configuration}")
        print(f"test_filter={args.test_filter}")
        print(f"launch_fingerprint={fingerprint}")
        expectation_kind = expected_mtp_expectation(args.expect_mtp_inactive)["kind"]
        print(
            f"report_fingerprint={build_configuration}:{expectation_kind}:{fingerprint}"
        )
        sys.stdout.flush()

        process = subprocess.Popen(
            command,
            cwd=PACKAGE_ROOT,
            env=environment,
            stdout=args._worker_log_fd,
            stderr=subprocess.STDOUT,
        )
        return_code = process.wait()
        if return_code != 0:
            print(f"live test failed with exit {return_code}; see {log_path}", file=sys.stderr)
            return return_code

        try:
            if artifact_facts(target_id, target) != target_facts:
                raise ValueError("target artifact drifted during the live run")
            if artifact_facts(assistant_id, assistant) != assistant_facts:
                raise ValueError("assistant artifact drifted during the live run")
        except (OSError, ValueError) as error:
            print(f"artifact drift validation failed: {error}; see {log_path}", file=sys.stderr)
            return 3

        if args.test_filter.startswith(DEFAULT_TEST_FILTER):
            try:
                validate_report(
                    run,
                    fingerprint=fingerprint,
                    launch_time=launch_time,
                    mode=args.mode,
                    build_configuration=build_configuration,
                    target=target_facts,
                    assistant=assistant_facts,
                    max_tokens=args.max_tokens,
                    warmup=warmup,
                    repetitions=repetitions,
                    seed=args.seed,
                    expect_mtp_inactive=args.expect_mtp_inactive,
                )
            except (OSError, ValueError, UnicodeDecodeError, json.JSONDecodeError) as error:
                print(
                    f"benchmark report validation failed: {error}; see {log_path}",
                    file=sys.stderr,
                )
                return 3
            print(output)
        else:
            print(f"focused live test passed; log={log_path}")
        return 0
    finally:
        run.close()


def supervisor_main(args: argparse.Namespace, warmup: int, repetitions: int) -> int:
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    requested = args.output or REPO_ROOT / "tmp/mtp-benchmarks" / f"mtp-{timestamp}.json"
    run = SecureRunDirectory.create(requested)
    log_descriptor = run.create_file(LOG_NAME)
    manifest = {
        "schema_version": 1,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "build_configuration": "debug" if args.debug else "release",
        "mode": args.mode,
        "mtp_expectation": expected_mtp_expectation(args.expect_mtp_inactive),
        "test_filter": args.test_filter,
        "timeout_seconds": args.timeout_seconds,
    }
    run.atomic_write(
        "run.json",
        (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode(),
    )

    worker_command = [
        sys.executable,
        str(Path(__file__).resolve()),
        *sys.argv[1:],
        "--_worker-run-directory",
        str(run.path),
        "--_worker-run-device",
        str(run.device),
        "--_worker-run-inode",
        str(run.inode),
        "--_worker-log-fd",
        str(log_descriptor),
    ]
    process: subprocess.Popen[Any] | None = None
    previous_handlers: dict[int, Any] = {}

    def handle_signal(signum: int, _frame: Any) -> None:
        if process is not None:
            terminate_group(process)
        raise SystemExit(128 + signum)

    try:
        process = subprocess.Popen(
            worker_command,
            pass_fds=(log_descriptor,),
            start_new_session=True,
        )
        for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            previous_handlers[signum] = signal.signal(signum, handle_signal)
        try:
            return_code = process.wait(timeout=args.timeout_seconds)
        except subprocess.TimeoutExpired:
            print(
                f"live test timed out after {args.timeout_seconds}s; see {run.path / LOG_NAME}",
                file=sys.stderr,
            )
            return_code = 124
        finally:
            terminate_group(process)
        if not run.visible_identity_matches():
            print("benchmark run directory path was replaced", file=sys.stderr)
            return 3
        return return_code
    finally:
        for signum, previous in previous_handlers.items():
            signal.signal(signum, previous)
        os.close(log_descriptor)
        run.close()


def self_test_output_safety() -> int:
    requested = Path(tempfile.gettempdir()) / f"mtp-self-test-{secrets.token_hex(8)}.json"
    run = SecureRunDirectory.create(requested)
    held = run.path.with_name(run.path.name + ".held")
    outside = run.path.with_name(run.path.name + ".outside")
    try:
        outside.mkdir(mode=0o700)
        victim = outside / "victim.json"
        victim.write_bytes(b"sentinel")
        os.symlink(victim, "probe.json", dir_fd=run.directory_fd)
        run.path.rename(held)
        run.path.symlink_to(outside, target_is_directory=True)
        run.atomic_write("probe.json", b"{}\n")
        if (
            not (held / "probe.json").is_file()
            or (outside / "probe.json").exists()
            or victim.read_bytes() != b"sentinel"
        ):
            raise RuntimeError("descriptor-relative write escaped after symlink replacement")
        print("secure output symlink-replacement self-test passed")
        return 0
    finally:
        run.close()
        try:
            run.path.unlink()
        except OSError:
            # Self-test teardown is best-effort; a failed unlink must not
            # mask the assertion result above.
            pass
        for path in (held, outside):
            try:
                for child in path.iterdir():
                    child.unlink()
                path.rmdir()
            except OSError:
                # Best-effort teardown: the directory may be non-empty or
                # already gone after the checks above.
                pass


def self_test_artifact_provenance() -> int:
    with tempfile.TemporaryDirectory(prefix="mtp-artifact-self-test-") as value:
        root = Path(value)
        repository = root / "models--example--assistant"
        snapshot = repository / "snapshots" / ("a" * 40)
        blobs = repository / "blobs"
        snapshot.mkdir(parents=True)
        blobs.mkdir()
        (snapshot / "config.json").write_text('{"model_type":"gemma4_assistant"}')
        first_oid = "b" * 64
        second_oid = "c" * 64
        (blobs / first_oid).write_bytes(b"first")
        (blobs / second_oid).write_bytes(b"other")
        weight = snapshot / "model.safetensors"
        weight.symlink_to(blobs / first_oid)
        model_id, resolved = resolve_model_snapshot(
            None, snapshot, DEFAULT_ASSISTANT_ID, "assistant"
        )
        before = artifact_facts(model_id, resolved)
        if (
            model_id != "example/assistant"
            or before["weightFiles"][0]["identityKind"] != "hf_blob_sha256"
            or before["weightFiles"][0]["contentIdentity"] != first_oid
        ):
            raise RuntimeError("Hugging Face blob provenance was not captured")
        try:
            resolve_model_snapshot(
                "wrong/assistant", snapshot, DEFAULT_ASSISTANT_ID, "assistant"
            )
        except SystemExit:
            pass
        else:
            raise RuntimeError("explicit model/path mismatch was accepted")
        weight.unlink()
        weight.symlink_to(blobs / second_oid)
        if artifact_facts(model_id, resolved) == before:
            raise RuntimeError("weight symlink drift was not detected")
    print("artifact provenance symlink self-test passed")
    return 0


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target-id")
    parser.add_argument("--assistant-id")
    parser.add_argument("--target-path", type=Path)
    parser.add_argument("--assistant-path", type=Path)
    parser.add_argument("--timeout-seconds", type=int, default=3600)
    parser.add_argument("--max-tokens", type=int, default=16)
    parser.add_argument(
        "--mode",
        choices=("raw-parity", "production-performance"),
        default="raw-parity",
        help="raw parity recursively omits performance keys; performance requires release",
    )
    parser.add_argument(
        "--expect-mtp-inactive",
        action="store_true",
        help=(
            "legacy pre-serial-target regression mode: require the retired Apple M5 "
            "hardware-veto reason and zero speculative work"
        ),
    )
    parser.add_argument("--warmup", type=int)
    parser.add_argument("--repetitions", type=int)
    parser.add_argument("--seed", type=int, default=0x4D545032)
    parser.add_argument(
        "--output",
        type=Path,
        help="select an approved temp root and run-name prefix; output is always unique",
    )
    parser.add_argument("--debug", action="store_true", help="use a debug Swift build")
    parser.add_argument(
        "--test-filter",
        default=DEFAULT_TEST_FILTER,
        help="Swift test filter; all env-gated MTP live tests remain process-supervised",
    )
    parser.add_argument("--self-test-output-safety", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--self-test-artifact-provenance", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--_worker-run-directory", type=Path, help=argparse.SUPPRESS)
    parser.add_argument("--_worker-run-device", type=int, help=argparse.SUPPRESS)
    parser.add_argument("--_worker-run-inode", type=int, help=argparse.SUPPRESS)
    parser.add_argument("--_worker-log-fd", type=int, help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.timeout_seconds <= 0 or args.max_tokens <= 0 or args.seed < 0:
        parser.error("--timeout-seconds and --max-tokens must be positive; --seed nonnegative")
    if args.mode == "production-performance" and args.debug:
        parser.error("production-performance mode requires a release build")
    if args.mode == "production-performance" and args.expect_mtp_inactive:
        parser.error("production-performance mode rejects --expect-mtp-inactive")
    if not args.test_filter or args.test_filter.startswith("-"):
        parser.error("--test-filter must be nonempty")
    return args


def main() -> int:
    args = parse_arguments()
    if args.self_test_output_safety:
        return self_test_output_safety()
    if args.self_test_artifact_provenance:
        return self_test_artifact_provenance()
    warmup = args.warmup if args.warmup is not None else (
        0 if args.mode == "raw-parity" else 1
    )
    repetitions = args.repetitions if args.repetitions is not None else (
        1 if args.mode == "raw-parity" else 3
    )
    if warmup < 0 or repetitions <= 0:
        raise SystemExit("--warmup must be nonnegative and --repetitions positive")
    internal_values = (
        args._worker_run_directory,
        args._worker_run_device,
        args._worker_run_inode,
        args._worker_log_fd,
    )
    if any(value is not None for value in internal_values):
        if any(value is None for value in internal_values):
            raise SystemExit("incomplete internal worker contract")
        return worker_main(args, warmup, repetitions)
    return supervisor_main(args, warmup, repetitions)


if __name__ == "__main__":
    raise SystemExit(main())
