"""Read-only checks for the installed broker-readable release tree."""

import ctypes
import errno
import os
from pathlib import Path
import stat
import sys


def require_no_extended_acl(path):
    if sys.platform != "darwin":
        raise ValueError("installed ACL validation requires macOS")
    library = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
    library.acl_get_fd_np.argtypes = [ctypes.c_int, ctypes.c_int]
    library.acl_get_fd_np.restype = ctypes.c_void_p
    library.acl_free.argtypes = [ctypes.c_void_p]
    library.acl_free.restype = ctypes.c_int
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    try:
        ctypes.set_errno(0)
        acl = library.acl_get_fd_np(descriptor, 0x100)  # ACL_TYPE_EXTENDED
        if acl:
            library.acl_free(acl)
            raise ValueError(f"unexpected extended ACL: {path}")
        if ctypes.get_errno() != errno.ENOENT:
            raise ValueError(f"cannot verify absence of extended ACL: {path}")
    finally:
        os.close(descriptor)


def validate_artifact_layout(root, owner_uid=0):
    root = Path(root)
    for path in [root, *root.rglob("*")]:
        metadata = path.lstat()
        mode = stat.S_IMODE(metadata.st_mode)
        if metadata.st_uid != owner_uid or path.is_symlink():
            raise ValueError(f"installed artifact has unsafe ownership or a symlink: {path}")
        if stat.S_ISDIR(metadata.st_mode):
            if mode not in (0o755, 0o555):
                raise ValueError(f"installed directory must be broker-traversable 0755 or 0555: {path}")
        elif stat.S_ISREG(metadata.st_mode):
            if metadata.st_nlink != 1 or mode not in (0o644, 0o444, 0o755, 0o555):
                raise ValueError(f"installed file must be readable and protected from broker writes: {path}")
        else:
            raise ValueError(f"installed artifact is not a regular file or directory: {path}")
        if "lume" in path.relative_to(root).parts and mode & 0o222:
            raise ValueError(f"pinned Lume must retain immutable modes: {path}")
        require_no_extended_acl(path)


def validate_install_ancestors(root):
    for path in Path(root).parents:
        metadata = path.lstat()
        if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != 0 or metadata.st_mode & 0o022 \
                or metadata.st_mode & 0o005 != 0o005:
            raise ValueError(f"install ancestor must be root-owned and broker-traversable: {path}")
        require_no_extended_acl(path)
