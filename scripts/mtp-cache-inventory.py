#!/usr/bin/env python3
"""Read-only inventory of cached Gemma 4 26B-A4B targets and assistants."""

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
MAX_CONFIG_BYTES = 4 * 1024 * 1024
MAX_CACHE_ROOT_ENTRIES = 4096
MAX_MATCHING_REPOSITORIES = 64
MAX_SNAPSHOTS_PER_REPOSITORY = 32
MAX_FILES_PER_SNAPSHOT = 256
MAX_TOTAL_ARTIFACTS = 128
DEFAULT_TIMEOUT_SECONDS = 30
KNOWN_MODEL_IDS = (
    "mlx-community/gemma-4-26B-A4B-it-qat-4bit",
    "mlx-community/gemma-4-26B-A4B-it-qat-assistant-4bit",
)
HEX_DIGITS = frozenset("0123456789abcdef")


def cache_roots() -> list[Path]:
    roots: list[Path] = []
    if value := os.environ.get("HUGGINGFACE_HUB_CACHE"):
        roots.append(Path(value).expanduser())
    if value := os.environ.get("HF_HOME"):
        roots.append(Path(value).expanduser() / "hub")
    roots.extend(
        [
            Path.home() / ".cache/huggingface/hub",
            Path.home() / "Library/Caches/huggingface/hub",
        ]
    )
    return list(dict.fromkeys(root.resolve() for root in roots if root.is_dir()))


def cache_repository_name(model_id: str) -> str:
    return "models--" + model_id.replace("/", "--")


def integer(value: Any) -> int | None:
    return value if isinstance(value, int) and not isinstance(value, bool) else None


def collect_nested_bit_overrides(value: Any, counts: dict[str, int]) -> None:
    if isinstance(value, dict):
        if (bits := integer(value.get("bits"))) is not None:
            key = str(bits)
            counts[key] = counts.get(key, 0) + 1
        for child in value.values():
            collect_nested_bit_overrides(child, counts)
    elif isinstance(value, list):
        for child in value:
            collect_nested_bit_overrides(child, counts)


def bounded_directory_entries(directory: Path, limit: int) -> tuple[list[os.DirEntry[str]], bool]:
    entries: list[os.DirEntry[str]] = []
    truncated = False
    try:
        with os.scandir(directory) as iterator:
            for entry in iterator:
                if len(entries) >= limit:
                    truncated = True
                    break
                entries.append(entry)
    except OSError:
        return [], False
    entries.sort(key=lambda entry: entry.name)
    return entries, truncated


def confined_regular_file(path: Path, allowed_root: Path) -> tuple[Path, os.stat_result]:
    resolved = path.resolve(strict=True)
    resolved_root = allowed_root.resolve(strict=True)
    if resolved != resolved_root and resolved_root not in resolved.parents:
        raise OSError(f"file escapes cache repository: {path} -> {resolved}")
    metadata = resolved.stat()
    if not stat.S_ISREG(metadata.st_mode):
        raise OSError(f"not a regular file: {path}")
    return resolved, metadata


def read_bounded_regular_file(path: Path, limit: int, allowed_root: Path) -> bytes:
    resolved, metadata = confined_regular_file(path, allowed_root)
    if metadata.st_size > limit:
        raise OSError(f"file exceeds {limit} byte limit: {metadata.st_size}")
    with resolved.open("rb") as handle:
        data = handle.read(limit + 1)
    if len(data) > limit:
        raise OSError(f"file exceeds {limit} byte limit while reading")
    return data


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


def snapshot_facts(
    repository: Path,
    snapshot: Path,
    main_revision: str | None,
) -> dict[str, Any]:
    config_path = snapshot / "config.json"
    config_data: bytes | None = None
    try:
        config_data = read_bounded_regular_file(config_path, MAX_CONFIG_BYTES, repository)
        config = json.loads(config_data)
        if not isinstance(config, dict):
            raise json.JSONDecodeError("config root is not an object", "", 0)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        config = {"_config_error": str(error)}

    quantization = config.get("quantization") or config.get("quantization_config") or {}
    override_counts: dict[str, int] = {}
    for value in quantization.values():
        collect_nested_bit_overrides(value, override_counts)
    weight_files: list[dict[str, Any]] = []
    snapshot_entries, files_truncated = bounded_directory_entries(
        snapshot, MAX_FILES_PER_SNAPSHOT
    )
    for entry in snapshot_entries:
        if not entry.name.endswith(".safetensors"):
            continue
        weight = Path(entry.path)
        try:
            resolved_weight, metadata = confined_regular_file(weight, repository)
            candidate = resolved_weight.name.lower()
            if (
                entry.is_symlink()
                and snapshot.parent.name == "snapshots"
                and resolved_weight.parent == repository / "blobs"
                and set(candidate) <= HEX_DIGITS
                and len(candidate) in {40, 64}
            ):
                identity_kind = (
                    "hf_blob_sha256" if len(candidate) == 64 else "hf_blob_git_sha1"
                )
                content_identity = candidate
            else:
                identity_kind = "sha256"
                content_identity = sha256_file(resolved_weight)
            weight_files.append(
                {
                    "name": weight.name,
                    "size_bytes": metadata.st_size,
                    "identity_kind": identity_kind,
                    "content_identity": content_identity,
                }
            )
        except OSError as error:
            weight_files.append({"name": weight.name, "size_error": str(error)})

    text = config.get("text_config") or {}
    model_type = config.get("model_type")
    if model_type == "gemma4_assistant":
        role = "assistant"
    elif model_type == "gemma4":
        role = "target"
    else:
        role = "other"
    repository_name = repository.name
    model_id = (
        "/".join(repository_name.removeprefix("models--").split("--"))
        if repository_name.startswith("models--")
        else None
    )
    config_sha256 = hashlib.sha256(config_data).hexdigest() if config_data is not None else None
    config_size = len(config_data) if config_data is not None else None
    artifact_fingerprint: str | None = None
    if model_id and config_sha256 and all("content_identity" in item for item in weight_files):
        payload = bytearray(b"darkbloom.mtp.artifact-fingerprint.v1")
        for value in (model_id, snapshot.name, str(config_size), config_sha256):
            append_fingerprint_field(payload, value)
        for weight in weight_files:
            for value in (
                weight["name"],
                str(weight["size_bytes"]),
                weight["identity_kind"],
                weight["content_identity"],
            ):
                append_fingerprint_field(payload, value)
        artifact_fingerprint = hashlib.sha256(payload).hexdigest()
    return {
        "cache_repository": str(repository),
        "model_id": model_id,
        "resolved_path": str(snapshot.resolve()),
        "revision": snapshot.name,
        "is_main_revision": snapshot.name == main_revision,
        "role": role,
        "model_type": model_type,
        "architectures": config.get("architectures"),
        "dtype": config.get("dtype"),
        "quantization": {
            "bits": integer(quantization.get("bits")),
            "group_size": integer(quantization.get("group_size")),
            "mode": quantization.get("mode"),
            "per_layer_overrides_by_bits": override_counts,
        }
        if quantization
        else None,
        "geometry": {
            "backbone_hidden_size": integer(config.get("backbone_hidden_size")),
            "hidden_size": integer(text.get("hidden_size")),
            "intermediate_size": integer(text.get("intermediate_size")),
            "num_hidden_layers": integer(text.get("num_hidden_layers")),
            "num_attention_heads": integer(text.get("num_attention_heads")),
            "num_key_value_heads": integer(text.get("num_key_value_heads")),
            "num_global_key_value_heads": integer(text.get("num_global_key_value_heads")),
            "num_experts": integer(text.get("num_experts")),
            "top_k_experts": integer(text.get("top_k_experts")),
            "max_position_embeddings": integer(text.get("max_position_embeddings")),
            "sliding_window": integer(text.get("sliding_window")),
            "layer_types": text.get("layer_types"),
        },
        "weight_file_count": len(weight_files),
        "weight_bytes": sum(
            entry.get("size_bytes", 0) for entry in weight_files if isinstance(entry, dict)
        ),
        "weight_files": weight_files,
        "config_size_bytes": config_size,
        "config_sha256": config_sha256,
        "artifact_fingerprint": artifact_fingerprint,
        "snapshot_file_scan_truncated": files_truncated,
        "config_error": config.get("_config_error"),
    }


def inventory() -> dict[str, Any]:
    artifacts: list[dict[str, Any]] = []
    warnings: list[str] = []
    matching_repositories = 0
    for root in cache_roots():
        repositories: list[Path] = []
        for model_id in KNOWN_MODEL_IDS:
            repository = root / cache_repository_name(model_id)
            try:
                metadata = repository.lstat()
            except OSError:
                continue
            if stat.S_ISDIR(metadata.st_mode):
                repositories.append(repository)

        root_entries, root_truncated = bounded_directory_entries(root, MAX_CACHE_ROOT_ENTRIES)
        if root_truncated:
            warnings.append(
                f"cache root entry scan truncated at {MAX_CACHE_ROOT_ENTRIES}: {root}"
            )
        for entry in root_entries:
            if not entry.name.startswith("models--") or not entry.is_dir(follow_symlinks=False):
                continue
            normalized = entry.name.lower()
            if "gemma-4-26b-a4b" not in normalized:
                continue
            repository = Path(entry.path)
            if repository not in repositories:
                repositories.append(repository)

        for repository in repositories:
            matching_repositories += 1
            if matching_repositories > MAX_MATCHING_REPOSITORIES:
                warnings.append(
                    f"matching repository scan truncated at {MAX_MATCHING_REPOSITORIES}"
                )
                break
            main_ref = repository / "refs/main"
            try:
                main_revision = read_bounded_regular_file(
                    main_ref, 256, repository
                ).decode().strip() or None
            except (OSError, UnicodeDecodeError):
                main_revision = None
            snapshots = repository / "snapshots"
            try:
                snapshots_metadata = snapshots.lstat()
            except OSError:
                continue
            if not stat.S_ISDIR(snapshots_metadata.st_mode):
                continue
            snapshot_entries, snapshots_truncated = bounded_directory_entries(
                snapshots, MAX_SNAPSHOTS_PER_REPOSITORY
            )
            if snapshots_truncated:
                warnings.append(
                    f"snapshot scan truncated at {MAX_SNAPSHOTS_PER_REPOSITORY}: {repository}"
                )
            for snapshot_entry in snapshot_entries:
                if not snapshot_entry.is_dir(follow_symlinks=False):
                    continue
                if len(artifacts) >= MAX_TOTAL_ARTIFACTS:
                    warnings.append(
                        f"artifact inventory truncated at {MAX_TOTAL_ARTIFACTS}"
                    )
                    break
                snapshot = Path(snapshot_entry.path)
                artifacts.append(snapshot_facts(repository, snapshot, main_revision))
            if len(artifacts) >= MAX_TOTAL_ARTIFACTS:
                break
        if matching_repositories > MAX_MATCHING_REPOSITORIES \
                or len(artifacts) >= MAX_TOTAL_ARTIFACTS:
            break

    extra_roots = [
        Path.home() / ".cache/mlx",
        Path.home() / "Library/Caches/mlx",
        Path.home() / ".darkbloom/spec-dec",
    ]
    return {
        "schema_version": 2,
        "cache_roots": [str(path) for path in cache_roots()],
        "additional_roots_checked": [
            {"path": str(path), "exists": path.exists()} for path in extra_roots
        ],
        "artifact_count": len(artifacts),
        "artifacts": artifacts,
        "bounds": {
            "max_config_bytes": MAX_CONFIG_BYTES,
            "max_cache_root_entries": MAX_CACHE_ROOT_ENTRIES,
            "max_matching_repositories": MAX_MATCHING_REPOSITORIES,
            "max_snapshots_per_repository": MAX_SNAPSHOTS_PER_REPOSITORY,
            "max_files_per_snapshot": MAX_FILES_PER_SNAPSHOT,
            "max_total_artifacts": MAX_TOTAL_ARTIFACTS,
        },
        "warnings": warnings,
    }


class SecureInventoryOutput:
    def __init__(self, root_fd: int, directory_fd: int, path: Path, name: str) -> None:
        self.root_fd = root_fd
        self.directory_fd = directory_fd
        self.path = path
        self.name = name

    @classmethod
    def create(cls, requested: Path) -> "SecureInventoryOutput":
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
        output_name = lexical.name or "inventory.json"
        if output_name in {".", ".."} or "/" in output_name:
            raise SystemExit("invalid inventory output filename")

        resolved_root = selected.resolve(strict=True)
        root_fd = os.open(
            resolved_root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
        )
        timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        for _ in range(32):
            directory_name = (
                f"mtp-inventory-{timestamp}-{secrets.token_hex(8)}.run"
            )
            try:
                os.mkdir(directory_name, mode=0o700, dir_fd=root_fd)
            except FileExistsError:
                continue
            directory_fd = os.open(
                directory_name,
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                dir_fd=root_fd,
            )
            metadata = os.fstat(directory_fd)
            if not stat.S_ISDIR(metadata.st_mode) or stat.S_IMODE(metadata.st_mode) != 0o700:
                os.close(directory_fd)
                os.close(root_fd)
                raise SystemExit("new inventory run directory is not private")
            return cls(
                root_fd,
                directory_fd,
                resolved_root / directory_name,
                output_name,
            )
        os.close(root_fd)
        raise SystemExit("could not allocate unique inventory output directory")

    @property
    def output_path(self) -> Path:
        return self.path / self.name

    def atomic_write(self, data: str) -> None:
        temporary = f".{self.name}.{secrets.token_hex(8)}.tmp"
        descriptor = os.open(
            temporary,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
            0o600,
            dir_fd=self.directory_fd,
        )
        try:
            encoded = data.encode()
            view = memoryview(encoded)
            while view:
                count = os.write(descriptor, view)
                if count <= 0:
                    raise OSError("short inventory output write")
                view = view[count:]
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
        try:
            os.replace(
                temporary,
                self.name,
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

    def close(self) -> None:
        os.close(self.directory_fd)
        os.close(self.root_fd)


def terminate_process_group(process: subprocess.Popen[Any]) -> None:
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        # The whole group already exited; nothing left to terminate.
        pass
    deadline = time.monotonic() + 2
    while process.poll() is None and time.monotonic() < deadline:
        time.sleep(0.05)
    if process.poll() is None:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            # The group exited between the deadline check and the kill.
            pass
    try:
        process.wait(timeout=2)
    except subprocess.TimeoutExpired:
        process.wait()


def self_test_output_safety() -> int:
    output = SecureInventoryOutput.create(
        Path(tempfile.gettempdir()) / "mtp-inventory-self-test.json"
    )
    held = output.path.with_name(output.path.name + ".held")
    outside = output.path.with_name(output.path.name + ".outside")
    try:
        outside.mkdir(mode=0o700)
        victim = outside / "victim.json"
        victim.write_bytes(b"sentinel")
        os.symlink(victim, output.name, dir_fd=output.directory_fd)
        output.path.rename(held)
        output.path.symlink_to(outside, target_is_directory=True)
        output.atomic_write("{}\n")
        if (
            not (held / output.name).is_file()
            or (outside / output.name).exists()
            or victim.read_bytes() != b"sentinel"
        ):
            raise RuntimeError("inventory write escaped after symlink replacement")
        print("inventory output symlink-replacement self-test passed")
        return 0
    finally:
        output.close()
        try:
            output.path.unlink()
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


def worker(output_path: Path | None) -> int:
    data = json.dumps(inventory(), indent=2, sort_keys=True) + "\n"
    if output_path:
        output = SecureInventoryOutput.create(output_path)
        try:
            output.atomic_write(data)
            print(output.output_path)
        finally:
            output.close()
    else:
        print(data, end="")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output",
        type=Path,
        help="optional name under repo tmp/system temp; written in a unique run directory",
    )
    parser.add_argument("--timeout-seconds", type=int, default=DEFAULT_TIMEOUT_SECONDS)
    parser.add_argument("--self-test-output-safety", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--_worker", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.timeout_seconds <= 0:
        parser.error("--timeout-seconds must be positive")
    if args.self_test_output_safety:
        return self_test_output_safety()
    if args._worker:
        return worker(args.output)

    process = subprocess.Popen(
        [sys.executable, str(Path(__file__).resolve()), *sys.argv[1:], "--_worker"],
        start_new_session=True,
    )
    try:
        try:
            return process.wait(timeout=args.timeout_seconds)
        except subprocess.TimeoutExpired:
            print(
                f"cache inventory timed out after {args.timeout_seconds}s",
                file=sys.stderr,
            )
            return 124
    finally:
        terminate_process_group(process)


if __name__ == "__main__":
    raise SystemExit(main())
