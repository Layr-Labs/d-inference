"""Read the Git index without trusting cache-supplied filesystem paths."""

from contextlib import contextmanager
from dataclasses import dataclass
import hashlib
import os
from pathlib import Path, PurePosixPath
import stat
import subprocess


EXCLUDED_PARTS = {".git", ".build", "target", "__pycache__"}


def safe_relative(path: object) -> bool:
    if not isinstance(path, str) or not path or "\\" in path:
        return False
    if any(ord(char) < 32 for char in path):
        return False
    parts = path.split("/")
    return not PurePosixPath(path).is_absolute() and all(
        part and part not in {".", ".."} | EXCLUDED_PARTS for part in parts
    )


@contextmanager
def open_file(root: Path, relative: str):
    """Use directory descriptors so a symlink cannot redirect a hash or utime."""
    if not safe_relative(relative):
        raise ValueError(f"Unsafe source path: {relative!r}")
    descriptors = [os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)]
    try:
        parts = relative.split("/")
        for part in parts[:-1]:
            descriptors.append(os.open(
                part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                dir_fd=descriptors[-1],
            ))
        descriptors.append(os.open(
            parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
            dir_fd=descriptors[-1],
        ))
        info = os.fstat(descriptors[-1])
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            raise ValueError("Source is not a single-link regular file")
        yield descriptors[-1]
    finally:
        for descriptor in reversed(descriptors):
            os.close(descriptor)


def hash_descriptor(descriptor: int) -> str:
    digest = hashlib.sha256()
    os.lseek(descriptor, 0, os.SEEK_SET)
    while chunk := os.read(descriptor, 1024 * 1024):
        digest.update(chunk)
    return digest.hexdigest()


def file_hash(root: Path, relative: str) -> str:
    with open_file(root, relative) as descriptor:
        return hash_descriptor(descriptor)


def git(root: Path, *arguments: str) -> bytes:
    return subprocess.check_output(["git", "-C", str(root), *arguments])


@dataclass
class Inventory:
    files: set[str]
    gitlinks: dict[str, str]


def inventory(root: Path) -> Inventory:
    """Include every recursive gitlink and regular tracked file, never outputs."""
    result = Inventory(set(), {})

    def visit(directory: Path, prefix: str = "") -> None:
        for record in git(directory, "ls-files", "--stage", "-z").split(b"\0"):
            if not record:
                continue
            metadata, raw_path = record.split(b"\t", 1)
            mode, object_id, stage = metadata.decode("ascii").split()
            path = prefix + raw_path.decode("utf-8")
            if stage != "0":
                raise ValueError("Cannot cache an index with unresolved conflicts")
            if not safe_relative(path):
                continue
            if mode == "160000":
                # A fresh recursive checkout must match the exact parent pin.
                # Checking every ancestor also rejects symlinked submodules.
                submodule = root.joinpath(*path.split("/"))
                cursor = root
                for part in path.split("/"):
                    cursor = cursor / part
                    if cursor.is_symlink():
                        raise ValueError(f"Symlinked submodule: {path}")
                if not (submodule / ".git").exists():
                    raise ValueError(f"Submodule is not initialized: {path}")
                head = git(submodule, "rev-parse", "HEAD").decode().strip()
                if head != object_id:
                    raise ValueError(f"Submodule differs from recorded gitlink: {path}")
                result.gitlinks[path] = head
                visit(submodule, path + "/")
            elif mode in {"100644", "100755"}:
                result.files.add(path)

    visit(root)
    return result
