"""Private bounded files for the reviewed test's exact provider-pointer swap."""
from contextlib import contextmanager
import fcntl
import hashlib
import os
from pathlib import Path
import stat
import uuid

MAXIMUM = 1024 * 1024


def digest(data):
    return hashlib.sha256(data).hexdigest()


def executable_hash(path):
    with directory(path.parent) as parent:
        fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
        try:
            before = os.fstat(fd)
            if (not stat.S_ISREG(before.st_mode) or before.st_nlink != 1 or before.st_uid != os.getuid()
                    or before.st_mode & 0o022 or not 0 < before.st_size <= 512 * MAXIMUM):
                raise ValueError('Unsafe bounded executable')
            result = hashlib.sha256()
            size = 0
            while True:
                block = os.read(fd, MAXIMUM)
                if not block: break
                size += len(block)
                if size > before.st_size: raise ValueError('Executable grew')
                result.update(block)
            after = os.fstat(fd)
            named = os.stat(path.name, dir_fd=parent, follow_symlinks=False)
            keys = ('st_dev', 'st_ino', 'st_size', 'st_mode', 'st_mtime_ns', 'st_ctime_ns')
            if (size != before.st_size or any(getattr(before, key) != getattr(after, key) for key in keys)
                    or (named.st_dev, named.st_ino) != (before.st_dev, before.st_ino)):
                raise ValueError('Executable changed')
            return result.hexdigest()
        finally:
            os.close(fd)


@contextmanager
def directory(path):
    path = Path(path)
    if not path.is_absolute() or '..' in path.parts:
        raise ValueError('Expected fixed absolute directory')
    fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in path.parts[1:]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd); fd = child
        info = os.fstat(fd)
        if info.st_uid != os.getuid() or info.st_mode & 0o022:
            raise ValueError('Unsafe configuration parent')
        yield fd
        current = path.lstat()
        if (current.st_dev, current.st_ino) != (info.st_dev, info.st_ino):
            raise ValueError('Configuration directory changed')
    finally:
        os.close(fd)


def read_at(parent, name):
    fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
    try:
        before = os.fstat(fd)
        if (not stat.S_ISREG(before.st_mode) or before.st_nlink != 1 or before.st_uid != os.getuid()
                or before.st_mode & 0o077 or not 0 <= before.st_size <= MAXIMUM):
            raise ValueError('Unsafe private regular file')
        data = bytearray()
        while len(data) <= MAXIMUM:
            part = os.read(fd, min(65536, MAXIMUM + 1 - len(data)))
            if not part: break
            data.extend(part)
        after = os.fstat(fd)
        names = ('st_dev', 'st_ino', 'st_mode', 'st_size', 'st_mtime_ns', 'st_ctime_ns')
        if len(data) != before.st_size or any(getattr(before, k) != getattr(after, k) for k in names):
            raise ValueError('Private input changed while reading')
        named = os.stat(name, dir_fd=parent, follow_symlinks=False)
        if (named.st_dev, named.st_ino) != (before.st_dev, before.st_ino):
            raise ValueError('Private input path changed')
        return bytes(data), stat.S_IMODE(before.st_mode)
    finally:
        os.close(fd)


def read_private(path):
    with directory(path.parent) as parent:
        return read_at(parent, path.name)


def publish(path, data, mode=0o600, expected=None):
    if len(data) > MAXIMUM or mode != 0o600:
        raise ValueError('Invalid private publication')
    with directory(path.parent) as parent:
        temporary = '.deadline-' + uuid.uuid4().hex
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode, dir_fd=parent)
        try:
            with os.fdopen(fd, 'wb') as stream:
                stream.write(data); stream.flush(); os.fsync(stream.fileno())
            if expected is None:
                # A new evidence file must not overwrite an existing entry.
                os.link(temporary, path.name, src_dir_fd=parent, dst_dir_fd=parent, follow_symlinks=False)
                os.unlink(temporary, dir_fd=parent)
            else:
                old, old_mode = read_at(parent, path.name)
                if digest(old) != expected or old_mode != mode:
                    raise ValueError('Provider configuration changed outside its lock')
                os.replace(temporary, path.name, src_dir_fd=parent, dst_dir_fd=parent)
            os.fsync(parent)
            observed, observed_mode = read_at(parent, path.name)
            if observed != data or observed_mode != mode:
                raise ValueError('Published private bytes differ')
        finally:
            try: os.unlink(temporary, dir_fd=parent)
            except FileNotFoundError: pass


@contextmanager
def locked(path, require_empty=False):
    with directory(path.parent) as parent:
        # Both locks already exist from the installed configure/device gate.
        fd = os.open(path.name, os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
        try:
            info = os.fstat(fd)
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                    or info.st_nlink != 1 or info.st_mode & 0o077):
                raise ValueError('Unsafe existing lock')
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            named = os.stat(path.name, dir_fd=parent, follow_symlinks=False)
            if (named.st_dev, named.st_ino) != (info.st_dev, info.st_ino):
                raise ValueError('Existing lock changed')
            if require_empty and os.fstat(fd).st_size != 0:
                raise ValueError('Native device journal remains nonempty')
            yield
            named = os.stat(path.name, dir_fd=parent, follow_symlinks=False)
            if (named.st_dev, named.st_ino) != (info.st_dev, info.st_ino):
                raise ValueError('Existing lock changed')
            if require_empty and os.fstat(fd).st_size != 0:
                raise ValueError('Native device journal changed')
        finally:
            os.close(fd)
