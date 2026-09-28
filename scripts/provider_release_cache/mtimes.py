"""Restore timestamps only for current tracked files with identical contents."""

from contextlib import contextmanager, ExitStack
import json
import os
from pathlib import Path
import re
import secrets
import stat
import sys

from .descriptors import open_descriptor, own_descriptor
from .tracked import hash_descriptor, inventory, open_file, safe_relative


MANIFEST = "provider-release-source-mtimes.json"
SCHEMA = 1
MAX_MANIFEST_BYTES = 32 * 1024 * 1024
MAX_ENTRIES = 100_000


@contextmanager
def manifest_directory(root: Path, create: bool = False):
    with ExitStack() as resources:
        descriptor = own_descriptor(resources, root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        for component in ("provider-swift", ".build"):
            if create and component == ".build":
                try:
                    os.mkdir(component, dir_fd=descriptor)
                except FileExistsError:
                    # A restored Swift cache normally already has this directory.
                    pass
            descriptor = own_descriptor(
                resources, component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                dir_fd=descriptor,
            )
        yield descriptor


def stable_stat(before: os.stat_result, after: os.stat_result) -> bool:
    return (before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns) == (
        after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns,
    )


def snapshot(root: Path) -> dict[str, int]:
    root = root.resolve(strict=True)
    files = []
    skipped = 0
    for path in sorted(inventory(root).files):
        try:
            with open_file(root, path) as descriptor:
                before = os.fstat(descriptor)
                sha = hash_descriptor(descriptor)
                after = os.fstat(descriptor)
                if not stable_stat(before, after):
                    skipped += 1
                    continue
                files.append({"path": path, "sha256": sha, "mtime_ns": after.st_mtime_ns})
        except (OSError, ValueError):
            # Tracked paths may have been deleted or replaced by symlinks.
            skipped += 1
    payload = json.dumps({"schema": SCHEMA, "root": str(root), "files": files},
                         separators=(",", ":")).encode()
    if len(payload) > MAX_MANIFEST_BYTES or len(files) > MAX_ENTRIES:
        raise ValueError("Source timestamp snapshot exceeds the safety limit")
    with manifest_directory(root, create=True) as directory:
        temporary = f".{MANIFEST}.{secrets.token_hex(8)}"
        with open_descriptor(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                             0o600, dir_fd=directory) as descriptor:
            try:
                with os.fdopen(descriptor, "wb", closefd=False) as output:
                    output.write(payload)
                os.replace(temporary, MANIFEST, src_dir_fd=directory, dst_dir_fd=directory)
            finally:
                try:
                    os.unlink(temporary, dir_fd=directory)
                except FileNotFoundError:
                    # Atomic replacement already moved the owned temporary file.
                    pass
    return {"snapshotted": len(files), "skipped": skipped}


def validate_manifest(payload: object, root: Path) -> list[dict]:
    if not isinstance(payload, dict) or set(payload) != {"schema", "root", "files"}:
        raise ValueError("Invalid timestamp manifest shape")
    if type(payload["schema"]) is not int or payload["schema"] != SCHEMA:
        raise ValueError("Unsupported timestamp manifest schema")
    if payload["root"] != str(root):
        raise ValueError("Timestamp manifest belongs to a different checkout path")
    files = payload["files"]
    if not isinstance(files, list) or len(files) > MAX_ENTRIES:
        raise ValueError("Invalid timestamp manifest file list")
    seen = set()
    for entry in files:
        if not isinstance(entry, dict) or set(entry) != {"path", "sha256", "mtime_ns"}:
            raise ValueError("Invalid timestamp manifest entry")
        path = entry["path"]
        if not safe_relative(path) or path in seen:
            raise ValueError("Unsafe or duplicate timestamp manifest path")
        seen.add(path)
        if not isinstance(entry["sha256"], str) or not re.fullmatch(r"[0-9a-f]{64}", entry["sha256"]):
            raise ValueError("Invalid source content hash")
        if type(entry["mtime_ns"]) is not int or not 0 <= entry["mtime_ns"] <= 2**63 - 1:
            raise ValueError("Invalid source timestamp")
    return files


def read_manifest(root: Path) -> list[dict]:
    with manifest_directory(root) as directory:
        with open_descriptor(MANIFEST, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                             dir_fd=directory) as descriptor:
            with os.fdopen(descriptor, "rb", closefd=False) as source:
                info = os.fstat(descriptor)
                if not stat.S_ISREG(info.st_mode) or info.st_size > MAX_MANIFEST_BYTES:
                    raise ValueError("Unsafe timestamp manifest file")
                raw = source.read(MAX_MANIFEST_BYTES + 1)
                if len(raw) > MAX_MANIFEST_BYTES:
                    raise ValueError("Timestamp manifest exceeds the safety limit")
    return validate_manifest(json.loads(raw), root)


def restore(root: Path) -> dict[str, int]:
    root = root.resolve(strict=True)
    try:
        entries = read_manifest(root)
    except FileNotFoundError:
        return {"restored": 0, "skipped": 0}
    except (OSError, ValueError, UnicodeError, RecursionError) as error:
        print(f"warning: Ignoring cached source timestamps: {error}", file=sys.stderr)
        return {"restored": 0, "skipped": 0}
    # Fully validate the manifest before changing any timestamp; Git provides
    # the independent allowlist, so a valid but stale entry cannot target an
    # untracked file, cached output, or repository metadata.
    tracked = inventory(root).files
    restored = 0
    for entry in entries:
        if entry["path"] not in tracked:
            continue
        try:
            with open_file(root, entry["path"]) as descriptor:
                before = os.fstat(descriptor)
                sha = hash_descriptor(descriptor)
                after = os.fstat(descriptor)
                if sha != entry["sha256"] or not stable_stat(before, after):
                    continue
                os.utime(descriptor, ns=(after.st_atime_ns, entry["mtime_ns"]))
                restored += 1
        except (OSError, ValueError):
            continue
    return {"restored": restored, "skipped": len(entries) - restored}
