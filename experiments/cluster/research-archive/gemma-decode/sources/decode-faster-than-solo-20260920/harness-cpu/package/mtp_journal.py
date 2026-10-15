"""Read-only canonical device-journal observations; never clears ownership."""
import fcntl
import hashlib
import os
from pathlib import Path
import pwd
import stat

from binding_common import require, same


def device_directory():
    return Path(pwd.getpwuid(os.geteuid()).pw_dir)/'.darkbloom/cluster-device'


def observe(directory):
    directory = Path(directory)
    require(directory.is_absolute() and directory.resolve() == directory, 'Device directory contains a link')
    parent = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    descriptor = None
    try:
        ds = os.fstat(parent)
        require(ds.st_uid == os.geteuid() and ds.st_mode & 0o077 == 0, 'Device directory must be private and owned')
        descriptor = os.open('native-device.lease', os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK,
                             dir_fd=parent)
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        before = os.fstat(descriptor)
        require(stat.S_ISREG(before.st_mode) and before.st_uid == os.geteuid() and before.st_nlink == 1
                and before.st_mode & 0o077 == 0 and 0 <= before.st_size <= 16384, 'Unsafe device journal')
        raw = os.pread(descriptor, 16385, 0)
        after = os.fstat(descriptor)
        named = os.stat('native-device.lease', dir_fd=parent, follow_symlinks=False)
        stamp = lambda s:(s.st_dev,s.st_ino,s.st_mode,s.st_nlink,s.st_size,s.st_mtime_ns,s.st_ctime_ns)
        require(stamp(before) == stamp(after) == stamp(named) and len(raw) == before.st_size,
                'Device journal changed during observation')
        named_directory = directory.lstat()
        require((named_directory.st_dev,named_directory.st_ino) == (ds.st_dev,ds.st_ino), 'Device directory changed')
        return dict(path=str(directory/'native-device.lease'), directoryDevice=ds.st_dev,
            directoryInode=ds.st_ino, fileDevice=before.st_dev, fileInode=before.st_ino,
            bytes=len(raw), sha256=hashlib.sha256(raw).hexdigest(), exclusiveObservationLockAcquired=True,
            journalMutationPerformed=False)
    finally:
        if descriptor is not None:
            os.close(descriptor)
        os.close(parent)


def require_empty(value, original=None):
    same(value['bytes'], 0, 'Device journal remains unresolved')
    same(value['sha256'], hashlib.sha256(b'').hexdigest(), 'Empty journal digest')
    if original is not None:
        for key in ('path','directoryDevice','directoryInode','fileDevice','fileInode'):
            same(value[key], original[key], 'Device journal identity changed')
