"""Select only the frozen 512/1024 warmups and unchanged exact 8192 workload."""
import hashlib
import json
import os
from pathlib import Path
import stat
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parent.parent
SMALL = ROOT / 'installed-http-small-warmup-prompts-20260915'
LONG = ROOT / 'installed-http-long-prompts-20260915'
SMALL_MANIFEST = 'eeac9a84049d4d5f441fcf46d26d5bb839f7e9758cd1f6600309ae5fb0890770'
LONG_MANIFEST = '5d97049c6998aaab9f1e85c3a56ab079642227f3d724e0e56c283fe6f3a2a240'
CLIENT_MANIFEST = '809b6e9685d3bd3bf4e5c0e1f909f7b787a56c149a6e4792b8acb914ea0e6d0c'


def bounded_bytes(path, maximum):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or not 0 < before.st_size <= maximum:
            raise ValueError('Invalid bounded input shape: ' + str(path))
        data = bytearray()
        while len(data) <= before.st_size:
            part = os.read(fd, min(65536, before.st_size + 1 - len(data)))
            if not part:
                break
            data.extend(part)
        same = lambda s: (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns)
        if len(data) != before.st_size or same(before) != same(os.fstat(fd)) or same(before) != same(os.lstat(path)):
            raise ValueError('Bounded input changed: ' + str(path))
        return bytes(data)
    finally:
        os.close(fd)


def fixture(root, manifest_name, digest, count):
    manifest_path = root / manifest_name
    raw = bounded_bytes(manifest_path, 65536)
    if hashlib.sha256(raw).hexdigest() != digest:
        raise ValueError('Frozen fixture manifest differs')
    members = {row['path']: row for row in json.loads(raw)['members']}
    paths = [root / ('fixtures/prompt-' + str(count) + suffix)
             for suffix in ('.txt', '.rendered.txt', '.ids.json', '.request.json')]
    for path in paths:
        raw = bounded_bytes(path, 262144)
        row = members[str(path.relative_to(root))]
        if len(raw) != row['bytes'] or hashlib.sha256(raw).hexdigest() != row['sha256']:
            raise ValueError('Frozen prompt bytes differ')
    return paths, manifest_path


def workloads(warmup_tokens):
    if type(warmup_tokens) is not int or warmup_tokens not in (512, 1024):
        raise ValueError('Warmup must contain exactly 512 or 1024 templated tokens')
    warm, small_manifest = fixture(SMALL, 'manifest.json', SMALL_MANIFEST, warmup_tokens)
    measured, long_manifest = fixture(LONG, 'fixture-manifest.json', LONG_MANIFEST, 8192)
    return SimpleNamespace(warmup_prompt_file=warm[0], warmup_rendered_prompt=warm[1],
        warmup_expected_token_ids=warm[2], warmup_prompt_tokens=warmup_tokens,
        prompt_file=measured[0], rendered_prompt=measured[1], expected_token_ids=measured[2],
        declared_prompt_tokens=8192, pinned_files=warm + measured + [small_manifest, long_manifest])


def client_files(client):
    raw = bounded_bytes(client.parent / 'manifest.json', 65536)
    if client.name != 'client.py' or hashlib.sha256(raw).hexdigest() != CLIENT_MANIFEST:
        raise ValueError('Use the unchanged frozen normal HTTP client')
    members = {row['path']: row for row in json.loads(raw)['members']}
    files = [client.parent / name for name in ('client.py', 'client_inputs.py',
             'client_observation.py', 'client_timeout.py', 'streaming_latency.py')]
    for path in files:
        raw = bounded_bytes(path, 65536)
        row = members[path.name]
        if len(raw) != row['bytes'] or hashlib.sha256(raw).hexdigest() != row['sha256']:
            raise ValueError('Frozen normal HTTP client source differs')
    return files + [client.parent / 'manifest.json']
