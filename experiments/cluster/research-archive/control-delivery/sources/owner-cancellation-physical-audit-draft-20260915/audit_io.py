"""Bounded local snapshots only; no subprocess, launcher import or network."""
import hashlib
import json
import math
import os
import stat
from pathlib import Path
from audit_records import require


def parse(raw):
    def pairs(values):
        result = {}
        for key, value in values:
            require(key not in result, 'Duplicate JSON key')
            result[key] = value
        return result
    def bad(value):
        raise ValueError('Nonfinite JSON number: ' + value)
    def floating(value):
        result = float(value)
        require(math.isfinite(result), 'Nonfinite JSON floating literal')
        return result
    return json.loads(raw, object_pairs_hook=pairs, parse_constant=bad, parse_float=floating)


class Inputs:
    def __init__(self):
        self.pins = {}

    def raw(self, path, maximum=16*1024*1024):
        path = Path(path)
        fd = os.open(str(path), os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        try:
            before = os.fstat(fd)
            require(stat.S_ISREG(before.st_mode) and 0 <= before.st_size <= maximum, 'Input is not bounded regular file')
            chunks, count = [], 0
            while True:
                chunk = os.read(fd, min(65536, maximum + 1 - count))
                if not chunk:
                    break
                chunks.append(chunk); count += len(chunk)
                require(count <= maximum, 'Input grew past bound')
            after = os.fstat(fd)
            require((before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns) ==
                    (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns), 'Input changed')
            raw = b''.join(chunks)
            require(len(raw) == before.st_size, 'Input length differs')
        finally:
            os.close(fd)
        digest = hashlib.sha256(raw).hexdigest()
        require(str(path) not in self.pins or self.pins[str(path)] == digest, 'Input pin changed')
        self.pins[str(path)] = digest
        return raw

    def obj(self, path):
        return parse(self.raw(path))

    def lines(self, path):
        raw = self.raw(path)
        require(raw.endswith(b'\n') and b'\r' not in raw, 'Missing JSONL final LF or unexpected CR')
        rows = raw[:-1].split(b'\n')
        require(all(rows), 'Empty JSONL record')
        return [parse(v) for v in rows]
