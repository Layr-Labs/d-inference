"""Subprocess, hashing, source fingerprinting, and atomic file helpers."""

from __future__ import annotations

import hashlib
import json
import shlex
import subprocess
import sys
from pathlib import Path


def run_step(
    command: list[str], cwd: Path, env: dict[str, str] | None = None
) -> None:
    print(f"+ {shlex.join(command)}", file=sys.stderr, flush=True)
    subprocess.run(command, cwd=cwd, check=True, env=env)


def run_json(command: list[str], cwd: Path) -> dict:
    print(f"+ {shlex.join(command)}", file=sys.stderr, flush=True)
    result = subprocess.run(
        command,
        cwd=cwd,
        check=False,
        stdout=subprocess.PIPE,
        text=True,
    )
    if result.returncode != 0:
        if result.stdout:
            print(result.stdout, file=sys.stderr)
        raise subprocess.CalledProcessError(result.returncode, command)
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as error:
        print(result.stdout, file=sys.stderr)
        raise RuntimeError(f"benchmark emitted invalid JSON: {error}") from error


def capture(command: list[str], cwd: Path) -> str:
    result = subprocess.run(
        command,
        cwd=cwd,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    return result.stdout.strip()


def capture_optional(command: list[str], cwd: Path) -> str:
    try:
        return capture(command, cwd)
    except (OSError, subprocess.CalledProcessError):
        return "unavailable"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def source_fingerprint(path: Path) -> tuple[list[str], str]:
    status = capture(["git", "status", "--short"], path).splitlines()
    digest = hashlib.sha256()
    digest.update(capture(["git", "rev-parse", "HEAD"], path).encode())
    if status:
        tracked_diff = subprocess.run(
            ["git", "diff", "--binary", "HEAD"],
            cwd=path,
            check=True,
            stdout=subprocess.PIPE,
        ).stdout
        digest.update(tracked_diff)
        untracked = capture(
            ["git", "ls-files", "--others", "--exclude-standard"], path
        ).splitlines()
        for relative in sorted(untracked):
            source = path / relative
            digest.update(relative.encode())
            if source.is_file():
                with source.open("rb") as handle:
                    for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                        digest.update(chunk)
    return status, digest.hexdigest()


def atomic_write(path: Path, content: str) -> None:
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(content, encoding="utf-8")
    temporary.replace(path)
