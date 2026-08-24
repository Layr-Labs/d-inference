#!/usr/bin/env python3

"""Fail-closed filesystem operations for publishing the pinned Lume runtime."""

from __future__ import annotations

import argparse
import ctypes
import errno
import os
import platform
import re
import stat
import sys
from collections.abc import Iterator
from contextlib import contextmanager
from dataclasses import dataclass


STAGING_NAME = re.compile(r"[.]darkbloom-lume-install[.][A-Za-z0-9]+")
STAGING_ROOT_MODE = 0o700
PUBLISHED_DIRECTORY_MODE = 0o555
PUBLISHED_FILE_MODE = 0o444
PUBLISHED_EXECUTABLE_MODE = 0o555
RENAME_EXCL = 0x00000004
RENAME_NOREPLACE = 0x00000001
ACL_TYPE_EXTENDED = 0x00000100
ACL_FIRST_ENTRY = 0


class PublicationError(RuntimeError):
    """A publication contract violation."""


@dataclass(frozen=True)
class FileIdentity:
    device: int
    inode: int

    @classmethod
    def parse(cls, value: str) -> FileIdentity:
        try:
            device_text, inode_text = value.split(":", maxsplit=1)
            identity = cls(int(device_text), int(inode_text))
        except (TypeError, ValueError) as error:
            raise PublicationError("invalid Lume staging identity") from error
        if identity.device < 0 or identity.inode <= 0:
            raise PublicationError("invalid Lume staging identity")
        return identity

    @classmethod
    def from_stat(cls, metadata: os.stat_result) -> FileIdentity:
        return cls(metadata.st_dev, metadata.st_ino)

    def __str__(self) -> str:
        return f"{self.device}:{self.inode}"


@dataclass
class OpenTree:
    parent_path: str
    tree_path: str
    tree_name: str
    parent_fd: int
    tree_fd: int
    identity: FileIdentity


def fail(message: str) -> None:
    raise PublicationError(message)


def require_canonical_absolute_path(path: str, subject: str) -> str:
    if not os.path.isabs(path):
        fail(f"{subject} must be absolute: {path}")
    normalized = os.path.normpath(path)
    if normalized != path or os.path.realpath(path) != path:
        fail(f"{subject} must be canonical and symlink-free: {path}")
    return path


def require_child_path(parent: str, child: str, subject: str) -> str:
    if not os.path.isabs(child) or os.path.normpath(child) != child:
        fail(f"{subject} must be a normalized absolute path: {child}")
    if os.path.dirname(child) != parent:
        fail(f"{subject} must be an immediate child of {parent}: {child}")
    name = os.path.basename(child)
    if name in {"", ".", ".."} or any(ord(character) < 32 for character in name):
        fail(f"{subject} has an unsafe name: {child}")
    return name


def require_staging_name(name: str) -> None:
    if STAGING_NAME.fullmatch(name) is None:
        fail(f"refusing unsafe Lume staging name: {name}")


def directory_open_flags() -> int:
    return (
        os.O_RDONLY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )


def regular_open_flags() -> int:
    return os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)


def open_parent(parent: str) -> int:
    parent = require_canonical_absolute_path(parent, "Lume install parent")
    before = os.lstat(parent)
    if not stat.S_ISDIR(before.st_mode):
        fail(f"Lume install parent is not a directory: {parent}")
    descriptor = os.open(parent, directory_open_flags())
    after = os.fstat(descriptor)
    if FileIdentity.from_stat(before) != FileIdentity.from_stat(after):
        os.close(descriptor)
        fail(f"Lume install parent changed while opening: {parent}")
    return descriptor


def stat_child(parent_fd: int, name: str) -> os.stat_result | None:
    try:
        return os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except FileNotFoundError:
        return None


def require_owned_directory(metadata: os.stat_result, subject: str) -> None:
    if not stat.S_ISDIR(metadata.st_mode):
        fail(f"{subject} is not a directory")
    if metadata.st_uid != os.geteuid():
        fail(f"{subject} is not owned by the current user")


@contextmanager
def open_tree(
    parent: str,
    tree: str,
    expected_identity: FileIdentity | None,
    *,
    require_staging: bool,
) -> Iterator[OpenTree]:
    parent = require_canonical_absolute_path(parent, "Lume install parent")
    tree_name = require_child_path(parent, tree, "Lume runtime tree")
    if require_staging:
        require_staging_name(tree_name)

    parent_fd = open_parent(parent)
    tree_fd = -1
    try:
        metadata = stat_child(parent_fd, tree_name)
        if metadata is None:
            fail(f"Lume runtime tree does not exist: {tree}")
        require_owned_directory(metadata, "Lume runtime tree")
        identity = FileIdentity.from_stat(metadata)
        if expected_identity is not None and identity != expected_identity:
            fail(f"Lume runtime tree identity changed: {tree}")

        tree_fd = os.open(tree_name, directory_open_flags(), dir_fd=parent_fd)
        opened = os.fstat(tree_fd)
        if FileIdentity.from_stat(opened) != identity:
            fail(f"Lume runtime tree changed while opening: {tree}")

        yield OpenTree(
            parent_path=parent,
            tree_path=tree,
            tree_name=tree_name,
            parent_fd=parent_fd,
            tree_fd=tree_fd,
            identity=identity,
        )
    finally:
        if tree_fd >= 0:
            os.close(tree_fd)
        os.close(parent_fd)


def relative_child(relative: str, name: str) -> str:
    return name if not relative else f"{relative}/{name}"


def sorted_entries(descriptor: int) -> list[os.DirEntry[str]]:
    with os.scandir(descriptor) as iterator:
        return sorted(iterator, key=lambda entry: entry.name)


def require_safe_name(name: str) -> None:
    if name in {"", ".", ".."} or "/" in name or any(ord(character) < 32 for character in name):
        fail(f"Lume runtime tree contains an unsafe entry name: {name!r}")


def require_owned_entry(metadata: os.stat_result, relative: str) -> None:
    if metadata.st_uid != os.geteuid():
        fail(f"Lume runtime entry is not owned by the current user: {relative}")


def descriptor_has_acl(descriptor: int) -> bool:
    if platform.system() != "Darwin":
        return False
    libc = ctypes.CDLL(None, use_errno=True)
    get_acl = libc.acl_get_fd_np
    get_acl.argtypes = [ctypes.c_int, ctypes.c_int]
    get_acl.restype = ctypes.c_void_p
    get_entry = libc.acl_get_entry
    get_entry.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.POINTER(ctypes.c_void_p)]
    get_entry.restype = ctypes.c_int
    free_acl = libc.acl_free
    free_acl.argtypes = [ctypes.c_void_p]
    free_acl.restype = ctypes.c_int

    ctypes.set_errno(0)
    acl = get_acl(descriptor, ACL_TYPE_EXTENDED)
    if not acl:
        error_number = ctypes.get_errno()
        if error_number == errno.ENOENT:
            return False
        raise OSError(error_number, os.strerror(error_number))
    entry = ctypes.c_void_p()
    ctypes.set_errno(0)
    result = get_entry(acl, ACL_FIRST_ENTRY, ctypes.byref(entry))
    entry_error = ctypes.get_errno()
    ctypes.set_errno(0)
    free_result = free_acl(acl)
    free_error = ctypes.get_errno()
    if free_result != 0:
        raise OSError(free_error, os.strerror(free_error))
    if result < 0:
        if entry_error == errno.EINVAL:
            return False
        raise OSError(entry_error, os.strerror(entry_error))
    return True


def require_no_acl(descriptor: int, relative: str) -> None:
    try:
        has_acl = descriptor_has_acl(descriptor)
    except OSError as error:
        raise PublicationError(
            f"could not inspect the Lume runtime ACL: {relative}"
        ) from error
    if has_acl:
        fail(f"Lume runtime entry retains an ACL: {relative}")


def clear_descriptor_acl(descriptor: int) -> None:
    if platform.system() != "Darwin":
        return
    libc = ctypes.CDLL(None, use_errno=True)
    init_acl = libc.acl_init
    init_acl.argtypes = [ctypes.c_int]
    init_acl.restype = ctypes.c_void_p
    set_acl = libc.acl_set_fd_np
    set_acl.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_int]
    set_acl.restype = ctypes.c_int
    free_acl = libc.acl_free
    free_acl.argtypes = [ctypes.c_void_p]
    free_acl.restype = ctypes.c_int

    ctypes.set_errno(0)
    empty_acl = init_acl(0)
    if not empty_acl:
        error_number = ctypes.get_errno()
        raise PublicationError("could not allocate an empty staging ACL") from OSError(
            error_number, os.strerror(error_number)
        )
    ctypes.set_errno(0)
    result = set_acl(descriptor, empty_acl, ACL_TYPE_EXTENDED)
    operation_error = ctypes.get_errno()
    ctypes.set_errno(0)
    free_result = free_acl(empty_acl)
    free_error = ctypes.get_errno()
    if result != 0:
        raise PublicationError("could not clear the staging root ACL") from OSError(
            operation_error, os.strerror(operation_error)
        )
    if free_result != 0:
        raise OSError(free_error, os.strerror(free_error))
    require_no_acl(descriptor, ".")


def require_regular_single_link(metadata: os.stat_result, relative: str) -> None:
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
        fail(f"Lume runtime tree contains an unsupported entry: {relative}")


def inspect_tree(
    descriptor: int,
    expected_root_mode: int,
    *,
    seal: bool,
    relative: str = "",
) -> tuple[set[str], set[str]]:
    root_metadata = os.fstat(descriptor)
    require_owned_directory(root_metadata, "Lume runtime directory")
    if not seal and stat.S_IMODE(root_metadata.st_mode) != expected_root_mode:
        fail(
            "Lume runtime directory has unexpected mode "
            f"{stat.S_IMODE(root_metadata.st_mode):04o}: {relative or '.'}"
        )
    require_no_acl(descriptor, relative or ".")
    action = "sealing" if seal else "verifying"

    directories: set[str] = set()
    files: set[str] = set()
    for entry in sorted_entries(descriptor):
        require_safe_name(entry.name)
        child_relative = relative_child(relative, entry.name)
        metadata = entry.stat(follow_symlinks=False)
        require_owned_entry(metadata, child_relative)
        if stat.S_ISDIR(metadata.st_mode):
            child_fd = os.open(entry.name, directory_open_flags(), dir_fd=descriptor)
            try:
                opened = os.fstat(child_fd)
                if FileIdentity.from_stat(opened) != FileIdentity.from_stat(metadata):
                    fail(f"Lume runtime directory changed while {action}: {child_relative}")
                require_owned_entry(opened, child_relative)
                child_directories, child_files = inspect_tree(
                    child_fd,
                    PUBLISHED_DIRECTORY_MODE,
                    seal=seal,
                    relative=child_relative,
                )
                if seal:
                    os.fchmod(child_fd, PUBLISHED_DIRECTORY_MODE)
            finally:
                os.close(child_fd)
            directories.add(child_relative)
            directories.update(child_directories)
            files.update(child_files)
            continue
        require_regular_single_link(metadata, child_relative)
        child_fd = os.open(entry.name, regular_open_flags(), dir_fd=descriptor)
        try:
            opened = os.fstat(child_fd)
            if FileIdentity.from_stat(opened) != FileIdentity.from_stat(metadata):
                fail(f"Lume runtime file changed while {action}: {child_relative}")
            require_owned_entry(opened, child_relative)
            require_regular_single_link(opened, child_relative)
            require_no_acl(child_fd, child_relative)
            expected_mode = (
                PUBLISHED_EXECUTABLE_MODE
                if child_relative == "lume"
                else PUBLISHED_FILE_MODE
            )
            if seal:
                os.fchmod(child_fd, expected_mode)
            elif stat.S_IMODE(opened.st_mode) != expected_mode:
                fail(
                    "Lume runtime file has unexpected mode "
                    f"{stat.S_IMODE(opened.st_mode):04o}: {child_relative}"
                )
        finally:
            os.close(child_fd)
        files.add(child_relative)

    return directories, files


def require_complete_tree(directories: set[str], files: set[str]) -> None:
    if "lume" not in files:
        fail("Lume runtime tree is missing its executable")
    if "lume.provenance.json" not in files:
        fail("Lume runtime tree is missing its provenance")
    if "lume_lume.bundle" not in directories:
        fail("Lume runtime tree is missing its resource bundle")


def require_tree_binding(tree: OpenTree, action: str) -> None:
    metadata = stat_child(tree.parent_fd, tree.tree_name)
    if metadata is None or FileIdentity.from_stat(metadata) != tree.identity:
        fail(f"Lume runtime tree changed while {action}: {tree.tree_path}")


def command_identity(arguments: argparse.Namespace) -> None:
    with open_tree(
        arguments.parent,
        arguments.tree,
        expected_identity=None,
        require_staging=True,
    ) as tree:
        print(tree.identity)


def command_initialize_staging(arguments: argparse.Namespace) -> None:
    with open_tree(
        arguments.parent,
        arguments.tree,
        expected_identity=None,
        require_staging=True,
    ) as tree:
        if sorted_entries(tree.tree_fd):
            fail("Lume staging root must be empty during initialization")
        clear_descriptor_acl(tree.tree_fd)
        os.fchmod(tree.tree_fd, STAGING_ROOT_MODE)
        require_tree_binding(tree, "initializing")
        print(tree.identity)


def command_require_absent(arguments: argparse.Namespace) -> None:
    parent = require_canonical_absolute_path(arguments.parent, "Lume install parent")
    destination_name = require_child_path(
        parent,
        arguments.destination,
        "Lume install destination",
    )
    parent_fd = open_parent(parent)
    try:
        if stat_child(parent_fd, destination_name) is not None:
            fail(
                "refusing to overwrite existing or ambiguous Lume install path: "
                f"{arguments.destination}"
            )
    finally:
        os.close(parent_fd)


def command_seal_staging(arguments: argparse.Namespace) -> None:
    expected_identity = FileIdentity.parse(arguments.identity)
    with open_tree(
        arguments.parent,
        arguments.tree,
        expected_identity=expected_identity,
        require_staging=True,
    ) as tree:
        directories, files = inspect_tree(
            tree.tree_fd,
            STAGING_ROOT_MODE,
            seal=True,
        )
        os.fchmod(tree.tree_fd, STAGING_ROOT_MODE)
        require_complete_tree(directories, files)
        verified_directories, verified_files = inspect_tree(
            tree.tree_fd,
            STAGING_ROOT_MODE,
            seal=False,
        )
        require_complete_tree(verified_directories, verified_files)


def exclusive_rename(parent_fd: int, source_name: str, destination_name: str) -> None:
    system = platform.system()
    libc = ctypes.CDLL(None, use_errno=True)
    source = os.fsencode(source_name)
    destination = os.fsencode(destination_name)

    if system == "Darwin":
        rename = libc.renameatx_np
        rename.argtypes = [
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_uint,
        ]
        rename.restype = ctypes.c_int
        result = rename(
            parent_fd,
            source,
            parent_fd,
            destination,
            RENAME_EXCL,
        )
    elif system == "Linux":
        try:
            rename = libc.renameat2
        except AttributeError as error:
            raise PublicationError(
                "this platform lacks atomic no-replace rename support"
            ) from error
        rename.argtypes = [
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_uint,
        ]
        rename.restype = ctypes.c_int
        result = rename(
            parent_fd,
            source,
            parent_fd,
            destination,
            RENAME_NOREPLACE,
        )
    else:
        fail(f"unsupported Lume publication platform: {system}")

    if result != 0:
        error_number = ctypes.get_errno()
        if error_number == errno.EEXIST:
            fail(f"Lume install destination already exists: {destination_name}")
        if error_number in {errno.ENOTSUP, errno.EINVAL}:
            fail("the install filesystem lacks atomic no-replace rename support")
        raise PublicationError(
            f"atomic Lume publication failed: {os.strerror(error_number)}"
        )


def command_publish(arguments: argparse.Namespace) -> None:
    expected_identity = FileIdentity.parse(arguments.identity)
    parent = require_canonical_absolute_path(arguments.parent, "Lume install parent")
    destination_name = require_child_path(
        parent,
        arguments.destination,
        "Lume install destination",
    )
    committed = False
    try:
        with open_tree(
            parent,
            arguments.staging,
            expected_identity=expected_identity,
            require_staging=True,
        ) as tree:
            directories, files = inspect_tree(
                tree.tree_fd,
                STAGING_ROOT_MODE,
                seal=False,
            )
            require_complete_tree(directories, files)
            exclusive_rename(tree.parent_fd, tree.tree_name, destination_name)
            committed = True

            if arguments.test_fail_after_rename:
                fail("injected post-rename failure")

            published_metadata = stat_child(tree.parent_fd, destination_name)
            if published_metadata is None:
                fail("published Lume destination disappeared")
            if FileIdentity.from_stat(published_metadata) != expected_identity:
                fail("published Lume destination has the wrong identity")
            os.fchmod(tree.tree_fd, PUBLISHED_DIRECTORY_MODE)

            directories, files = inspect_tree(
                tree.tree_fd,
                PUBLISHED_DIRECTORY_MODE,
                seal=False,
            )
            require_complete_tree(directories, files)
    except Exception as error:
        if committed:
            raise PublicationError(
                "Lume publication committed but finalization failed; "
                f"destination retained for inspection: {arguments.destination}; {error}"
            ) from error
        raise


def command_verify(arguments: argparse.Namespace) -> None:
    expected_identity = FileIdentity.parse(arguments.identity)
    with open_tree(
        arguments.parent,
        arguments.tree,
        expected_identity=expected_identity,
        require_staging=False,
    ) as tree:
        directories, files = inspect_tree(
            tree.tree_fd,
            PUBLISHED_DIRECTORY_MODE,
            seal=False,
        )
        require_complete_tree(directories, files)


def remove_tree_contents(descriptor: int) -> None:
    os.fchmod(descriptor, STAGING_ROOT_MODE)
    for entry in sorted_entries(descriptor):
        require_safe_name(entry.name)
        metadata = entry.stat(follow_symlinks=False)
        if stat.S_ISDIR(metadata.st_mode):
            child_fd = os.open(entry.name, directory_open_flags(), dir_fd=descriptor)
            try:
                opened = os.fstat(child_fd)
                if FileIdentity.from_stat(opened) != FileIdentity.from_stat(metadata):
                    fail(f"Lume staging directory changed during cleanup: {entry.name}")
                remove_tree_contents(child_fd)
            finally:
                os.close(child_fd)
            rebound = stat_child(descriptor, entry.name)
            if rebound is None or FileIdentity.from_stat(rebound) != FileIdentity.from_stat(
                metadata
            ):
                fail(f"Lume staging directory changed before removal: {entry.name}")
            os.rmdir(entry.name, dir_fd=descriptor)
            continue
        os.unlink(entry.name, dir_fd=descriptor)


def command_cleanup(arguments: argparse.Namespace) -> None:
    expected_identity = FileIdentity.parse(arguments.identity)
    parent = require_canonical_absolute_path(arguments.parent, "Lume install parent")
    tree_name = require_child_path(parent, arguments.tree, "Lume staging tree")
    require_staging_name(tree_name)
    parent_fd = open_parent(parent)
    tree_fd = -1
    try:
        metadata = stat_child(parent_fd, tree_name)
        if metadata is None:
            return
        require_owned_directory(metadata, "Lume staging tree")
        if FileIdentity.from_stat(metadata) != expected_identity:
            fail(f"refusing cleanup of replaced Lume staging tree: {arguments.tree}")
        tree_fd = os.open(tree_name, directory_open_flags(), dir_fd=parent_fd)
        opened = os.fstat(tree_fd)
        if FileIdentity.from_stat(opened) != expected_identity:
            fail(f"Lume staging tree changed during cleanup: {arguments.tree}")

        remove_tree_contents(tree_fd)
        rebound = stat_child(parent_fd, tree_name)
        if rebound is None or FileIdentity.from_stat(rebound) != expected_identity:
            fail(
                "Lume staging namespace became ambiguous during cleanup; "
                f"emptied expected root retained: {arguments.tree}"
            )
        os.rmdir(tree_name, dir_fd=parent_fd)
    finally:
        if tree_fd >= 0:
            os.close(tree_fd)
        os.close(parent_fd)


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    commands = root.add_subparsers(dest="command", required=True)

    identity = commands.add_parser("identity")
    identity.add_argument("parent")
    identity.add_argument("tree")
    identity.set_defaults(handler=command_identity)

    initialize_staging = commands.add_parser("initialize-staging")
    initialize_staging.add_argument("parent")
    initialize_staging.add_argument("tree")
    initialize_staging.set_defaults(handler=command_initialize_staging)

    require_absent = commands.add_parser("require-absent")
    require_absent.add_argument("parent")
    require_absent.add_argument("destination")
    require_absent.set_defaults(handler=command_require_absent)

    seal_staging = commands.add_parser("seal-staging")
    seal_staging.add_argument("parent")
    seal_staging.add_argument("tree")
    seal_staging.add_argument("identity")
    seal_staging.set_defaults(handler=command_seal_staging)

    publish = commands.add_parser("publish")
    publish.add_argument("parent")
    publish.add_argument("staging")
    publish.add_argument("destination")
    publish.add_argument("identity")
    publish.add_argument(
        "--test-fail-after-rename",
        action="store_true",
        help=argparse.SUPPRESS,
    )
    publish.set_defaults(handler=command_publish)

    verify = commands.add_parser("verify")
    verify.add_argument("parent")
    verify.add_argument("tree")
    verify.add_argument("identity")
    verify.set_defaults(handler=command_verify)

    cleanup = commands.add_parser("cleanup")
    cleanup.add_argument("parent")
    cleanup.add_argument("tree")
    cleanup.add_argument("identity")
    cleanup.set_defaults(handler=command_cleanup)

    return root


def main() -> int:
    arguments = parser().parse_args()
    try:
        arguments.handler(arguments)
    except (OSError, PublicationError) as error:
        print(f"lume runtime publication error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
