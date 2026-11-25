"""Bounded local input reads for this private configuration materializer."""
import hashlib
import json
import os
import re
import stat


def require(value, message):
    if not value:
        raise ValueError(message)


def read_json(path, maximum=500_000):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    try:
        before = os.fstat(fd)
        require(stat.S_ISREG(before.st_mode) and 0 < before.st_size <= maximum,
                'Input must be a bounded regular file')
        chunks, total = [], 0
        while True:
            block = os.read(fd, min(65_536, maximum + 1 - total))
            if not block:
                break
            chunks.append(block)
            total += len(block)
            require(total <= maximum, 'Input exceeds bound')
        after = os.fstat(fd)
        fields = ('st_dev', 'st_ino', 'st_mode', 'st_size', 'st_mtime_ns', 'st_ctime_ns')
        require(total == before.st_size and all(getattr(before, k) == getattr(after, k) for k in fields),
                'Input changed during read')
        raw = b''.join(chunks)
    finally:
        os.close(fd)

    def unique(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, 'Duplicate JSON key')
            result[key] = value
        return result

    value = json.loads(raw, object_pairs_hook=unique,
                       parse_constant=lambda _: (_ for _ in ()).throw(ValueError('Nonfinite JSON')))
    return value, hashlib.sha256(raw).hexdigest()


def tokens(value, count):
    require(isinstance(value, list) and len(value) == count
            and all(type(x) is int and 0 <= x < 248_320 for x in value), 'Token packet differs')
    return value


def digest(value):
    require(isinstance(value, str) and re.fullmatch('[0-9a-f]{64}', value), 'Expected SHA-256')
    return value


def absolute_path(value):
    require(isinstance(value, str) and value.startswith('/') and len(value) <= 900
            and re.fullmatch(r'[A-Za-z0-9_./-]+', value) and '..' not in value.split('/'), 'Invalid private path')
    return value.rstrip('/')
