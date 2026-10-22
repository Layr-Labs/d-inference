"""Bounded local evidence reads and prospective pin verification."""
import os
import stat
from pathlib import Path
from probe_values import digest, parse_json, require, fields, exact


def read_file(path, maximum):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(fd)
        require(stat.S_ISREG(before.st_mode) and 0 < before.st_size <= maximum, 'Not a bounded nonempty regular file')
        chunks = []
        remaining = before.st_size
        while remaining:
            part = os.read(fd, min(remaining, 65536))
            require(bool(part), 'Evidence file truncated')
            chunks.append(part); remaining -= len(part)
        require(os.read(fd, 1) == b'', 'Evidence file grew')
        after = os.fstat(fd)
        require((before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns) ==
                (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns), 'Evidence file changed')
        return b''.join(chunks)
    finally:
        os.close(fd)


def prospective(base):
    policy_raw = read_file(base / 'policy.json', 65536)
    policy = fields(parse_json(policy_raw), 'schema files nativeBinarySHA256 scope', 'policy')
    exact(policy['schema'], 'registered_mtp_probe_prospective_policy_v1', 'policy schema')
    expected = {'request.json', 'configuration/expected-agreement.json', 'configuration/controller.json',
                'probe_values.py', 'probe_validation.py', 'probe_io.py', 'validate_probe.py'}
    require(type(policy['files']) is dict and set(policy['files']) == expected, 'Policy closure differs')
    values = {}
    for name, pin in policy['files'].items():
        raw = read_file(base / name, 1_048_576)
        exact(digest(raw), pin, 'Prospective input ' + name)
        values[name] = raw
    return policy, digest(policy_raw), values
