"""Shared serialization, hashing, command, and secret-safety helpers."""

from __future__ import annotations

import hashlib
import json
import re
import subprocess
from pathlib import Path
from typing import Any, Iterable, Mapping, Sequence
from urllib.parse import urlsplit, urlunsplit


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
DEFAULT_ENV_NAMES = ("CI", "DEVELOPER_DIR", "SDKROOT")

SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
IMMUTABLE_REVISION_RE = re.compile(
    r"^(?:[0-9a-f]{40,64}|sha256:[0-9a-f]{64})$"
)
_SETTING_KEY_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_.-]{0,127}$")
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
    re.compile(
        r"^eyJ[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{8,}$"
    ),
    re.compile(
        r"^(?:gh[pousr]_|xox[baprs]-|sk_(?:live|test)_|rk_(?:live|test)_)\S+$"
    ),
    re.compile(r"^AKIA[0-9A-Z]{16}$"),
)


class ProvenanceError(RuntimeError):
    """Raised when decision-grade provenance cannot be captured."""


def canonical_json_bytes(value: Any) -> bytes:
    return json.dumps(
        value,
        allow_nan=False,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")


def pretty_json(value: Any) -> str:
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


def required_stdout(
    argv: Sequence[str], *, cwd: Path | None = None, timeout_seconds: int = 30
) -> str:
    result = run_command(argv, cwd=cwd, timeout_seconds=timeout_seconds)
    if result["exit_code"] != 0:
        detail = result["stderr"].strip() or result["stdout"].strip() or "unknown error"
        raise ProvenanceError(f"{' '.join(argv)} failed: {detail}")
    return result["stdout"].strip()


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
    return sanitized, sanitized != value


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
