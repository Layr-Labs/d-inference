#!/usr/bin/env python3
"""Deterministic, secret-safe provenance capture for Qwen prefill benchmarks."""

from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable, Mapping, Sequence
from urllib.parse import urlsplit, urlunsplit


SCHEMA_VERSION = 1
DEFAULT_ENV_PREFIXES = (
    "DARKBLOOM_",
    "HF_",
    "HUGGINGFACE_",
    "METAL_",
    "MLX_",
    "MTL_",
    "OMP_",
    "SWIFT_",
    "VECLIB_",
)
DEFAULT_ENV_NAMES = (
    "CI",
    "DEVELOPER_DIR",
    "SDKROOT",
)

_SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
_IMMUTABLE_REVISION_RE = re.compile(r"^(?:[0-9a-f]{40,64}|sha256:[0-9a-f]{64})$")
_SETTING_KEY_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_.-]{0,127}$")
_SUBMODULE_RE = re.compile(
    r"^(?P<state>[ +\-U])(?P<sha>[0-9a-fA-F]{40,64})\s+"
    r"(?P<path>\S+)(?:\s+\((?P<description>.*)\))?$"
)
_SENSITIVE_KEY_RE = re.compile(
    r"(?:^|[_\-.])(?:"
    r"API[_-]?KEY|AUTH|BEARER|CERT|CODE|COOKIE|CREDENTIAL|DATABASE[_-]?URL|"
    r"DSN|KEY|MNEMONIC|PASS(?:WORD|WD)?|SECRET|SEED|SESSION|TOKEN|WEBHOOK"
    r")(?:$|[_\-.])",
    re.IGNORECASE,
)
_SECRET_VALUE_RES = (
    re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
    re.compile(r"(?i)^bearer\s+\S+"),
    re.compile(r"^eyJ[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{8,}$"),
    re.compile(r"^(?:gh[pousr]_|xox[baprs]-|sk_(?:live|test)_|rk_(?:live|test)_)\S+$"),
    re.compile(r"^AKIA[0-9A-Z]{16}$"),
)


class ProvenanceError(RuntimeError):
    """Raised when decision-grade provenance cannot be captured."""


def canonical_json_bytes(value: Any) -> bytes:
    """Serialize value in the stable form used by all provenance hashes."""
    return json.dumps(
        value,
        allow_nan=False,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")


def pretty_json(value: Any) -> str:
    """Serialize a human-readable provenance document deterministically."""
    return json.dumps(
        value,
        allow_nan=False,
        ensure_ascii=False,
        indent=2,
        sort_keys=True,
    ) + "\n"


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def display_path(path: Path) -> str:
    """Render paths without baking a local account name into artifacts."""
    absolute = path.expanduser().absolute()
    home = Path.home().absolute()
    try:
        return "~/" + absolute.relative_to(home).as_posix()
    except ValueError:
        return absolute.as_posix()


def file_record(path: Path, *, required: bool = True) -> dict[str, Any]:
    expanded = path.expanduser()
    if not expanded.is_file():
        if required:
            raise ProvenanceError(f"required file is missing: {display_path(expanded)}")
        return {"exists": False, "path": display_path(expanded)}
    return {
        "exists": True,
        "path": display_path(expanded),
        "sha256": sha256_file(expanded),
        "size_bytes": expanded.stat().st_size,
    }


def _truncate(value: str, limit: int = 32_768) -> str:
    if len(value) <= limit:
        return value
    return value[:limit] + f"\n<truncated {len(value) - limit} characters>"


def run_command(
    argv: Sequence[str],
    *,
    cwd: Path | None = None,
    timeout_seconds: int = 30,
) -> dict[str, Any]:
    """Run a fixed argv without a shell and retain bounded diagnostic output."""
    try:
        result = subprocess.run(
            list(argv),
            cwd=cwd,
            capture_output=True,
            check=False,
            text=True,
            timeout=timeout_seconds,
        )
    except FileNotFoundError:
        return {
            "argv": list(argv),
            "available": False,
            "exit_code": None,
            "stderr": "command not found",
            "stdout": "",
        }
    except subprocess.TimeoutExpired as error:
        stdout = error.stdout if isinstance(error.stdout, str) else ""
        stderr = error.stderr if isinstance(error.stderr, str) else ""
        return {
            "argv": list(argv),
            "available": True,
            "exit_code": None,
            "stderr": _truncate(stderr),
            "stdout": _truncate(stdout),
            "timed_out": True,
        }
    return {
        "argv": list(argv),
        "available": True,
        "exit_code": result.returncode,
        "stderr": _truncate(result.stderr),
        "stdout": _truncate(result.stdout),
    }


def _required_stdout(
    argv: Sequence[str], *, cwd: Path | None = None, timeout_seconds: int = 30
) -> str:
    result = run_command(argv, cwd=cwd, timeout_seconds=timeout_seconds)
    if result["exit_code"] != 0:
        detail = result["stderr"].strip() or result["stdout"].strip() or "unknown error"
        raise ProvenanceError(f"{' '.join(argv)} failed: {detail}")
    return result["stdout"].strip()


def _status_lines(repo: Path) -> list[str]:
    output = _required_stdout(
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

    head_sha = _required_stdout(["git", "rev-parse", "HEAD"], cwd=repo)
    tree_sha = _required_stdout(["git", "rev-parse", "HEAD^{tree}"], cwd=repo)
    root_status = _status_lines(repo)
    submodule_output = _required_stdout(
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
        submodule["head_sha"] = _required_stdout(
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


def _is_sensitive_key(key: str) -> bool:
    return _SENSITIVE_KEY_RE.search(key) is not None


def _looks_secret(value: str) -> bool:
    return any(pattern.search(value) is not None for pattern in _SECRET_VALUE_RES)


def _sanitize_url(value: str) -> tuple[str, bool]:
    try:
        parsed = urlsplit(value)
    except ValueError:
        return value, False
    if not parsed.scheme or not parsed.hostname:
        return value, False

    hostname = parsed.hostname
    if ":" in hostname and not hostname.startswith("["):
        hostname = f"[{hostname}]"
    netloc = hostname
    if parsed.port is not None:
        netloc += f":{parsed.port}"

    path = parsed.path
    for segment in path.split("/"):
        if len(segment) >= 32 and re.fullmatch(r"[A-Za-z0-9._~-]+", segment):
            path = "/<redacted-path>"
            break
    sanitized = urlunsplit((parsed.scheme, netloc, path, "", ""))
    changed = sanitized != value
    return sanitized, changed


def sanitize_value(key: str, value: str) -> dict[str, Any]:
    if _is_sensitive_key(key) or _looks_secret(value):
        return {"redacted": True, "value": "<redacted>"}
    sanitized, changed = _sanitize_url(value)
    return {"redacted": changed, "value": sanitized}


def capture_environment(
    environ: Mapping[str, str],
    *,
    extra_names: Iterable[str] = (),
    extra_prefixes: Iterable[str] = (),
) -> dict[str, dict[str, Any]]:
    names = set(DEFAULT_ENV_NAMES)
    names.update(extra_names)
    prefixes = tuple(DEFAULT_ENV_PREFIXES) + tuple(extra_prefixes)
    selected = {
        key: sanitize_value(key, value)
        for key, value in environ.items()
        if key in names or key.startswith(prefixes)
    }
    return dict(sorted(selected.items()))


def parse_settings(values: Iterable[str]) -> dict[str, dict[str, Any]]:
    settings: dict[str, dict[str, Any]] = {}
    for item in values:
        key, separator, value = item.partition("=")
        if not separator or not _SETTING_KEY_RE.fullmatch(key):
            raise ProvenanceError(
                f"benchmark setting must be a valid KEY=VALUE pair: {item!r}"
            )
        if key in settings:
            raise ProvenanceError(f"duplicate benchmark setting: {key}")
        settings[key] = sanitize_value(key, value)
    return dict(sorted(settings.items()))


def capture_configuration(
    config_paths: Sequence[Path],
    settings: Mapping[str, dict[str, Any]],
    environment: Mapping[str, dict[str, Any]],
) -> dict[str, Any]:
    files = [file_record(path) for path in config_paths]
    hash_payload = {
        "environment": environment,
        "files": [
            {
                "name": Path(record["path"]).name,
                "sha256": record["sha256"],
                "size_bytes": record["size_bytes"],
            }
            for record in files
        ],
        "settings": settings,
    }
    return {
        "files": files,
        "settings": settings,
        "sha256": sha256_bytes(canonical_json_bytes(hash_payload)),
    }


def _load_registry_manifest(path: Path) -> tuple[dict[str, Any], dict[str, Any]]:
    record = file_record(path)
    try:
        raw = json.loads(path.expanduser().read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ProvenanceError(f"invalid model registry manifest: {error}") from error
    if not isinstance(raw, dict) or not isinstance(raw.get("files"), list):
        raise ProvenanceError("model registry manifest must contain a files array")

    selected = {
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
    record["metadata"] = selected
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
            or not _SHA256_RE.fullmatch(digest)
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

    aggregate = manifest.get("aggregate_sha256")
    computed = hashlib.sha256(
        b"".join(digest for _, digest in sorted(digest_bytes))
    ).hexdigest()
    aggregate_valid = (
        isinstance(aggregate, str)
        and _SHA256_RE.fullmatch(aggregate) is not None
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
    return target_name if _SHA256_RE.fullmatch(target_name) else None


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

    metadata_records: list[dict[str, Any]] = []
    metadata_by_relative_path: dict[str, dict[str, Any]] = {}
    for path in _metadata_paths(model_path):
        relative = path.relative_to(model_path).as_posix()
        record = file_record(path)
        record["relative_path"] = relative
        metadata_records.append(record)
        metadata_by_relative_path[relative] = record
    if "config.json" not in metadata_by_relative_path:
        raise ProvenanceError("model directory is missing config.json")

    safetensor_paths = sorted(
        (path for path in model_path.rglob("*.safetensors") if path.is_file()),
        key=lambda path: path.relative_to(model_path).as_posix(),
    )
    if not safetensor_paths:
        raise ProvenanceError("model directory contains no safetensor shards")

    safetensor_records: list[dict[str, Any]] = []
    all_content_addressed = True
    registry_covers_safetensors = registry_manifest_path is not None
    for path in safetensor_paths:
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
        safetensor_records.append(
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

    registry_matches_lightweight_files = registry_manifest_path is not None
    if manifest is not None:
        for relative, declared in registry_files.items():
            actual_path = model_path / relative
            if not actual_path.is_file():
                manifest_issues.append(f"manifest file is missing: {relative}")
                registry_matches_lightweight_files = False
                continue
            if actual_path.stat().st_size != declared["size_bytes"]:
                manifest_issues.append(f"manifest file size mismatch: {relative}")
                registry_matches_lightweight_files = False
        for relative, record in metadata_by_relative_path.items():
            declared = registry_files.get(relative)
            if declared is not None and declared["sha256"] != record["sha256"]:
                manifest_issues.append(f"metadata digest mismatch: {relative}")
                registry_matches_lightweight_files = False

    inferred_revision = model_path.resolve().name.lower()
    lexical_revision = model_path.name.lower()
    revision = snapshot_id or (
        inferred_revision
        if _IMMUTABLE_REVISION_RE.fullmatch(inferred_revision)
        else lexical_revision
        if _IMMUTABLE_REVISION_RE.fullmatch(lexical_revision)
        else None
    )
    if snapshot_id is not None and not _IMMUTABLE_REVISION_RE.fullmatch(snapshot_id):
        raise ProvenanceError(
            "model snapshot id must be a 40-64 hex revision or sha256:<digest>"
        )

    registry_identity_complete = (
        aggregate_valid
        and registry_covers_safetensors
        and registry_matches_lightweight_files
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


def _capture_gpu_summary() -> dict[str, Any]:
    result = run_command(["system_profiler", "SPDisplaysDataType"])
    allowed_fields = {
        "Chipset Model": "chipset_model",
        "Metal Support": "metal_support",
        "Total Number of Cores": "core_count",
        "Vendor": "vendor",
    }
    adapters: list[dict[str, str]] = []
    current: dict[str, str] = {}
    if result["exit_code"] == 0:
        for line in result["stdout"].splitlines():
            key, separator, value = line.strip().partition(":")
            if not separator or key not in allowed_fields:
                continue
            if key == "Chipset Model" and current:
                adapters.append(current)
                current = {}
            current[allowed_fields[key]] = value.strip()
        if current:
            adapters.append(current)
    return {
        "adapters": adapters,
        "argv": result["argv"],
        "available": result["available"],
        "exit_code": result["exit_code"],
        "stderr": result["stderr"],
    }


def capture_host() -> dict[str, Any]:
    return {
        "hardware": {
            "gpu": _capture_gpu_summary(),
            "machine_model": run_command(["sysctl", "-n", "hw.model"]),
            "memory_bytes": run_command(["sysctl", "-n", "hw.memsize"]),
        },
        "os": {
            "sw_vers": run_command(["sw_vers"]),
            "uname": run_command(["uname", "-srvmp"]),
        },
        "toolchain": {
            "metal": run_command(["xcrun", "-sdk", "macosx", "metal", "--version"]),
            "metallib": run_command(
                ["xcrun", "-sdk", "macosx", "metallib", "--version"]
            ),
            "swift": run_command(["swift", "--version"]),
            "xcode": run_command(["xcodebuild", "-version"]),
        },
    }


def capture_power_and_thermal() -> dict[str, Any]:
    battery = run_command(["pmset", "-g", "batt"])
    custom = run_command(["pmset", "-g", "custom"])
    thermal = run_command(["pmset", "-g", "therm"])
    battery_output = battery["stdout"]
    custom_output = custom["stdout"]

    mode: int | None = None
    in_ac = False
    for line in custom_output.splitlines():
        if line.startswith("AC Power:"):
            in_ac = True
            continue
        if line and not line[0].isspace() and line.endswith("Power:"):
            in_ac = False
        if in_ac:
            match = re.match(r"\s*powermode\s+(\d+)\s*$", line)
            if match:
                mode = int(match.group(1))
                break

    return {
        "ac_power": "AC Power" in battery_output if battery["exit_code"] == 0 else None,
        "battery": battery,
        "power_mode_ac": mode,
        "settings": custom,
        "thermal": {
            "cpu_level": run_command(
                ["sysctl", "-n", "machdep.xcpm.cpu_thermal_level"]
            ),
            "gpu_level": run_command(
                ["sysctl", "-n", "machdep.xcpm.gpu_thermal_level"]
            ),
            "io_level": run_command(
                ["sysctl", "-n", "machdep.xcpm.io_thermal_level"]
            ),
            "pmset": thermal,
        },
    }


def capture_competing_processes(limit: int = 30) -> dict[str, Any]:
    if limit < 1:
        raise ProvenanceError("process limit must be positive")
    command = ["ps", "-axo", "pid=,ppid=,pcpu=,pmem=,etime=,comm="]
    result = run_command(command)
    entries: list[dict[str, Any]] = []
    if result["exit_code"] == 0:
        for line in result["stdout"].splitlines():
            fields = line.strip().split(None, 5)
            if len(fields) != 6:
                continue
            try:
                pid = int(fields[0])
                parent_pid = int(fields[1])
                cpu = float(fields[2])
                memory = float(fields[3])
            except ValueError:
                continue
            entries.append(
                {
                    "cpu_percent": cpu,
                    "elapsed": fields[4],
                    "executable": Path(fields[5]).name,
                    "memory_percent": memory,
                    "parent_pid": parent_pid,
                    "pid": pid,
                }
            )
        entries.sort(key=lambda item: (-item["cpu_percent"], item["pid"]))
        entries = entries[:limit]
    return {
        "capture": {
            "argv": result["argv"],
            "available": result["available"],
            "exit_code": result["exit_code"],
            "stderr": result["stderr"],
        },
        "entries": entries,
        "includes_command_arguments": False,
        "limit": limit,
    }


def capture_stderr_paths(paths: Sequence[Path]) -> list[dict[str, Any]]:
    return [file_record(path, required=False) for path in paths]


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace(
        "+00:00", "Z"
    )


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
