"""Read-only installed layout checks for the explicit GUI-user qualification plan."""

import os
import json
from pathlib import Path
import plistlib
import stat

from sandbox_gui_host_plan import UNVERIFIED, identity_document, installed_identity_path, installed_job_path, launch_agent
from sandbox_install_validation import require_no_extended_acl, validate_artifact_layout, validate_install_ancestors
from sandbox_release_support import require_encrypted_backing


def _exact_value(actual, expected):
    if type(actual) is not type(expected):
        return False
    if isinstance(expected, dict):
        return set(actual) == set(expected) and all(_exact_value(actual[key], value) for key, value in expected.items())
    if isinstance(expected, list):
        return len(actual) == len(expected) and all(_exact_value(left, right) for left, right in zip(actual, expected))
    return actual == expected


def canonical_path(path):
    path = Path(path)
    # Accept only the two fixed macOS system aliases also used by the runtime.
    if str(path) == "/var" or str(path).startswith("/var/") or str(path) == "/tmp" or str(path).startswith("/tmp/"):
        path = Path("/private" + str(path))
    if not path.is_absolute() or ".." in path.parts:
        raise ValueError("installed paths must be absolute and contain no traversal")
    return path


def validate_private_path(path, uid, mode, *, file=False):
    path = canonical_path(path)
    for parent in reversed(path.parents):
        metadata = parent.lstat()
        if (not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid not in (0, uid)
                or metadata.st_mode & 0o022):
            raise ValueError("private state ancestor has unsafe ownership or shared writes")
        require_no_extended_acl(parent)
    metadata = path.lstat()
    valid_type = stat.S_ISREG(metadata.st_mode) if file else stat.S_ISDIR(metadata.st_mode)
    if (not valid_type or metadata.st_uid != uid or stat.S_IMODE(metadata.st_mode) != mode
            or file and metadata.st_nlink != 1):
        raise ValueError("private state must have the selected user's ownership and exact private mode")
    require_no_extended_acl(path)
    return path


def read_root_file(path, mode, maximum_bytes):
    validate_install_ancestors(path)
    descriptor = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(descriptor)
        if (not stat.S_ISREG(before.st_mode) or before.st_uid != 0 or before.st_nlink != 1
                or stat.S_IMODE(before.st_mode) != mode or not 0 < before.st_size <= maximum_bytes):
            raise ValueError("host binding files must be root-owned, single-link and have the exact protected mode")
        require_no_extended_acl(path)
        data = bytearray()
        while len(data) <= before.st_size:
            part = os.read(descriptor, min(8192, before.st_size + 1 - len(data)))
            if not part:
                break
            data.extend(part)
        after = os.fstat(descriptor)
        named = Path(path).lstat()
        identity = lambda value: (value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns, value.st_ctime_ns)
        if (identity(before) != identity(after) or identity(before) != identity(named)
                or len(data) != before.st_size):
            raise ValueError("installed GUI job definition changed or differs from the selected plan")
        return bytes(data)
    finally:
        os.close(descriptor)


def validate_installed_job(path, expected):
    if not _exact_value(plistlib.loads(read_root_file(path, 0o644, 131072)), expected):
        raise ValueError("installed GUI job definition differs from the selected plan")


def validate_installed_identity(path, expected):
    if not _exact_value(json.loads(read_root_file(path, 0o444, 8192)), expected):
        raise ValueError("installed GUI user identity differs from the selected plan")


def validate_runtime_layout(runtime_gid):
    root = Path("/Library/Application Support/Darkbloom/runtime")
    validate_install_ancestors(root)
    directory = root.lstat()
    if (not stat.S_ISDIR(directory.st_mode) or directory.st_uid != 0 or directory.st_gid != runtime_gid
            or stat.S_IMODE(directory.st_mode) != 0o750):
        raise ValueError("machine runtime authority directory is not root-owned mode 0750 in its group")
    require_no_extended_acl(root)
    lock = root / "ownership.lock"
    metadata = lock.lstat()
    if (not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != 0 or metadata.st_gid != runtime_gid
            or stat.S_IMODE(metadata.st_mode) != 0o660 or metadata.st_nlink != 1 or metadata.st_size != 0):
        raise ValueError("machine runtime authority must be the existing empty root-owned single-link inode")
    require_no_extended_acl(lock)
    # Inspect only. Actual caller access/exclusion and preserved inode identity
    # are proven by HostRuntimeAuthority when the selected GUI process runs.
    return {"directory_device": directory.st_dev, "directory_inode": directory.st_ino,
            "lock_device": metadata.st_dev, "lock_inode": metadata.st_ino}


def validate_gui_installation(configuration, arguments, install_root, user, observations):
    if os.geteuid() != 0:
        raise ValueError("--verify-installed requires root to inspect all selected-user private paths")
    validate_install_ancestors(install_root)
    validate_artifact_layout(install_root)
    backing = {}
    for key in ("storageDirectory", "capacityDirectory"):
        path = validate_private_path(configuration[key], user.uid, 0o700)
        backing[key] = require_encrypted_backing(path)
    token = canonical_path(configuration["tokenFile"])
    validate_private_path(token.parent, user.uid, 0o700)
    validate_private_path(token, user.uid, 0o600, file=True)
    backing["tokenFile"] = require_encrypted_backing(token.parent)
    validate_installed_job(installed_job_path(configuration), launch_agent(arguments))
    validate_installed_identity(installed_identity_path(configuration), identity_document(configuration, user))
    authority = validate_runtime_layout(observations["runtime_gid"])
    return {"installed_layout_validated": True, "gui_user_identity_validated": True,
            "host_user": user.record(), "identity_observations": observations,
            "runtime_authority_metadata": authority, "encrypted_backing": backing,
            "production_ready": False, "not_verified": UNVERIFIED}
