"""Descriptor-relative private output creation and bounded reads/writes."""
from __future__ import annotations

from datetime import datetime, timezone
import os
from pathlib import Path
import secrets
import stat
import tempfile

from .constants import REPO_ROOT

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


