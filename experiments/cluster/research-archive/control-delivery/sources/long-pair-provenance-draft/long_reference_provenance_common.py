"""Bounded CPU file checks; no launcher imports, subprocesses or model reads."""
from dataclasses import dataclass
import hashlib
import json
import math
from pathlib import Path, PurePosixPath
import re


def require(value, message):
    if not value: raise ValueError(message)


def valid_hash(value):
    require(type(value) is str and re.fullmatch('[0-9a-f]{64}', value) is not None, 'Malformed SHA256 pin')
    return value


def sha(path):
    value = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024**2), b''): value.update(block)
    return value.hexdigest()


def raw(path, maximum=32 * 1024**2):
    path = Path(path)
    require(path.is_file() and not path.is_symlink(), 'Expected regular metadata file')
    with path.open('rb') as stream: data = stream.read(maximum + 1)
    require(len(data) <= maximum, 'Metadata byte bound exceeded')
    return data


def parse(data):
    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result, 'Duplicate metadata key'); result[key] = value
        return result
    def number(value):
        result = float(value); require(math.isfinite(result), 'Nonfinite metadata'); return result
    def invalid(value): raise ValueError('Nonfinite metadata')
    return json.loads(data, object_pairs_hook=pairs, parse_float=number, parse_constant=invalid)


def read(path): return parse(raw(path))


def safe_relative(value):
    require(type(value) is str, 'Invalid archive path type')
    path = PurePosixPath(value)
    require(value and not path.is_absolute() and str(path) == value
            and all(part not in ('.', '..') for part in path.parts), 'Unsafe archive path')
    return path


def files(base, entries):
    base = Path(base).resolve(strict=True)
    require(type(entries) is list and 1 <= len(entries) <= 4096, 'Unbounded file manifest')
    seen = set()
    for entry in entries:
        relative = safe_relative(entry['path']); path = base / relative
        require(entry['path'] not in seen, 'Duplicate archive path'); seen.add(entry['path'])
        require(not any(parent.is_symlink() for parent in [path, *path.parents] if parent != base.parent)
                and path.resolve(strict=True).is_relative_to(base), 'Archive escaped root or used symlink')
        size = entry['size_bytes']; valid_hash(entry['sha256'])
        require(type(size) is int and 0 <= size <= 2 * 1024**3 and path.stat().st_size == size
                and sha(path) == entry['sha256'], 'Archive size/hash differs: ' + entry['path'])
    return {entry['path']: entry['sha256'] for entry in entries}


@dataclass(frozen=True)
class Pins:
    native: str
    artifact: str
    configuration: str
    prompt: str
    origin: str

    def __post_init__(self):
        for value in (self.native, self.artifact, self.configuration, self.prompt, self.origin): valid_hash(value)
