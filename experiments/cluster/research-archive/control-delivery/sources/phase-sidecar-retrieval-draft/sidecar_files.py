"""Small bounded, exclusive local evidence IO; no model or process access."""
import hashlib
import json
import math
import os
from pathlib import Path
import re
import stat

MAX_SIDECAR = 512 * 1024


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def pin(value):
    require(isinstance(value, str) and re.fullmatch('[0-9a-f]{64}', value) is not None,
            'An explicit lower-case SHA256 is required')
    return value


def parse(data):
    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result, 'Duplicate JSON key')
            result[key] = value
        return result
    def invalid(value):
        raise ValueError('Nonfinite JSON constant: ' + value)
    def number(value):
        result = float(value)
        require(math.isfinite(result), 'Nonfinite JSON number')
        return result
    return json.loads(data, object_pairs_hook=pairs, parse_constant=invalid, parse_float=number)


def signature(value):
    return (value.st_dev, value.st_ino, value.st_mode, value.st_uid, value.st_gid,
            value.st_nlink, value.st_size, value.st_mtime_ns, value.st_ctime_ns)


def bounded_bytes(path, maximum):
    descriptor = os.open(str(path), os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(descriptor)
        require(stat.S_ISREG(before.st_mode) and 0 <= before.st_size <= maximum,
                'Local evidence is not a bounded regular file: ' + str(path))
        chunks, count = [], 0
        while count <= maximum:
            chunk = os.read(descriptor, min(65536, maximum + 1 - count))
            if not chunk:
                break
            chunks.append(chunk)
            count += len(chunk)
        require(count == before.st_size and signature(before) == signature(os.fstat(descriptor)),
                'Local evidence changed or exceeded its bound: ' + str(path))
        return b''.join(chunks)
    finally:
        os.close(descriptor)


def write_new(path, data):
    descriptor = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        os.fchmod(descriptor, 0o600)
        remaining = memoryview(data)
        while remaining:
            count = os.write(descriptor, remaining)
            require(count > 0, 'Short local evidence write')
            remaining = remaining[count:]
    finally:
        os.close(descriptor)


def write_json(path, value):
    write_new(path, (json.dumps(value, sort_keys=True, indent=2, allow_nan=False) + '\n').encode())


def file_record(path, data):
    return dict(path=str(Path(path)), sha256=sha(data), size_bytes=len(data))
