"""Exact frozen regular-file snapshot function; no path or launcher execution."""
import hashlib
import os
import stat
from recorded_math import require


def snapshot(path, maximum, keep=True, empty=False):
    descriptor = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, 'rb') as stream:
        before = os.fstat(stream.fileno())
        require(stat.S_ISREG(before.st_mode) and (0 if empty else 1) <= before.st_size <= maximum,
                'Expected bounded regular input file')
        digest, parts, size = hashlib.sha256(), [], 0
        while True:
            block = stream.read(min(1024**2, maximum + 1 - size))
            if not block:
                break
            size += len(block)
            require(size <= maximum, 'Input grew beyond its bound')
            digest.update(block)
            if keep:
                parts.append(block)
        after = os.fstat(stream.fileno())
    stamp = lambda s: (s.st_dev, s.st_ino, s.st_mode, s.st_size, s.st_mtime_ns, s.st_ctime_ns)
    require(size == before.st_size and stamp(before) == stamp(after), 'Input changed during snapshot')
    return dict(raw=b''.join(parts) if keep else None, sha256=digest.hexdigest(),
                size_bytes=size, identity=stamp(before))
