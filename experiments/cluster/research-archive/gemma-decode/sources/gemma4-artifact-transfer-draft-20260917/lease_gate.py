"""Exact acquired-FD gate extraction; no journal mutation."""
import fcntl,os,stat
from binding_common import require,same

def acquire(directory):
    require(directory.resolve() == directory, 'Canonical device directory contains a link')
    parent = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    fd = None
    try:
        ds = os.fstat(parent)
        require(ds.st_uid == os.geteuid() and ds.st_mode & 0o077 == 0, 'Unsafe canonical directory')
        fd = os.open('native-device.lease', os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK, dir_fd=parent)
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        value = os.fstat(fd); named = os.stat('native-device.lease', dir_fd=parent, follow_symlinks=False)
        require(stat.S_ISREG(value.st_mode) and value.st_uid == os.geteuid() and value.st_nlink == 1
                and value.st_mode & 0o077 == 0 and value.st_size == 0 and os.pread(fd,1,0)==b'', 'Canonical journal is unsafe or unresolved')
        identity = lambda s:(s.st_dev,s.st_ino,s.st_mode,s.st_nlink,s.st_size,s.st_mtime_ns,s.st_ctime_ns)
        same(identity(value),identity(named),'Canonical path identity')
        same((directory.lstat().st_dev,directory.lstat().st_ino),(ds.st_dev,ds.st_ino),'Canonical directory identity')
        return fd, dict(path=str(directory/'native-device.lease'),directoryDevice=ds.st_dev,directoryInode=ds.st_ino,
            fileDevice=value.st_dev,fileInode=value.st_ino,bytes=0,leaseFD=fd,ownerPID=os.getpid(),
            exclusiveLockHeld=True,inheritedAcrossExec=True,journalMutationPerformed=False,protocolReleaseACK=False)
    except BaseException:
        if fd is not None: os.close(fd)
        raise
    finally: os.close(parent)
