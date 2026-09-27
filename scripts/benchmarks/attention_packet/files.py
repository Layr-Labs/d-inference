"""Bounded, hashed packet files; no model, network, or device access."""

import hashlib
import json
from pathlib import PurePosixPath
import re
import stat

MAX_JSON_BYTES = 256 * 1024
MAX_TENSOR_BYTES = 32 * 1024 * 1024


class PacketError(ValueError):
    pass


class UnsupportedPacket(PacketError):
    pass


def require(condition, message):
    if not condition:
        raise PacketError(message)


def integer(value, name, minimum=0, maximum=2**63 - 1):
    require(type(value) is int and minimum <= value <= maximum, "invalid " + name)
    return value


def digest(value, name):
    require(isinstance(value, str) and re.fullmatch("[0-9a-f]{64}", value) is not None,
            "invalid " + name)
    return value


def sha256(raw):
    return hashlib.sha256(raw).hexdigest()


def read_bounded(path, limit, expected=None):
    info = path.stat()
    require(stat.S_ISREG(info.st_mode), "packet payload must be a regular file")
    require(info.st_size <= limit, "packet file exceeds byte budget")
    if expected is not None:
        require(info.st_size == expected, "packet file length mismatch")
    with path.open("rb") as source:
        raw = source.read(limit + 1)
    require(len(raw) <= limit and len(raw) == info.st_size, "packet file changed or exceeded budget")
    return raw


def parse_json(raw):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, "duplicate JSON key: " + key)
            result[key] = value
        return result
    def constant(value):
        raise PacketError("nonstandard JSON constant: " + value)
    try:
        value = json.loads(raw, object_pairs_hook=unique, parse_constant=constant)
    except (UnicodeDecodeError, json.JSONDecodeError, RecursionError) as error:
        raise PacketError("invalid bounded packet JSON") from error
    require(isinstance(value, dict), "packet JSON must be an object")
    return value


def payload_path(root, name, used):
    require(isinstance(name, str) and name and "\\" not in name and "\0" not in name,
            "invalid packet relative path")
    path = PurePosixPath(name)
    require(not path.is_absolute() and ".." not in path.parts, "packet path escapes directory")
    resolved = (root / name).resolve(strict=True)
    require(resolved.is_relative_to(root), "packet symlink escapes directory")
    require(resolved not in used, "duplicate packet payload file")
    used.add(resolved)
    return resolved


def hashed_file(root, descriptor, used, limit):
    require(isinstance(descriptor, dict), "invalid file descriptor")
    count = integer(descriptor.get("byteCount"), "byteCount", 1, limit)
    expected_hash = digest(descriptor.get("sha256"), "sha256")
    path = payload_path(root, descriptor.get("file"), used)
    raw = read_bounded(path, limit, count)
    require(sha256(raw) == expected_hash, "packet payload SHA256 mismatch")
    return raw
