"""Identity checks for executable bundles and registered model artifacts."""

import hashlib
import json
import re
from pathlib import Path, PurePosixPath


def file_sha256(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def contained_file(directory, name):
    if not isinstance(name, str) or '\\' in name:
        raise ValueError('Artifact names must be relative POSIX paths')
    relative = PurePosixPath(name)
    if (relative.is_absolute() or '..' in relative.parts or not relative.parts
            or str(relative) != name):
        raise ValueError(f'Invalid artifact path: {name}')
    path = (directory / name).resolve(strict=True)
    if not path.is_relative_to(directory.resolve()) or not path.is_file():
        raise ValueError(f'Artifact escapes its directory or is not a file: {name}')
    return path


def verify_files(directory, entries):
    if not isinstance(entries, list):
        raise ValueError('Artifact files must be an array')
    seen, digests = set(), {}
    for entry in entries:
        if not isinstance(entry, dict):
            raise ValueError('Artifact entries must be objects')
        name = entry.get('path')
        if not isinstance(name, str):
            raise ValueError('Artifact names must be relative POSIX paths')
        if name in seen:
            raise ValueError(f'Duplicate artifact entry: {name}')
        seen.add(name)
        path = contained_file(directory, name)
        if type(entry.get('size_bytes')) is not int or entry['size_bytes'] < 0:
            raise ValueError(f'Invalid artifact size: {name}')
        if not isinstance(entry.get('sha256'), str) or not re.fullmatch(r'[0-9a-f]{64}', entry['sha256']):
            raise ValueError(f'Invalid artifact SHA-256: {name}')
        if path.stat().st_size != entry['size_bytes']:
            raise ValueError(f'Artifact size mismatch: {name}')
        digest = file_sha256(path)
        if digest != entry['sha256']:
            raise ValueError(f'Artifact hash mismatch: {name}')
        digests[name] = digest
    if not digests:
        raise ValueError('Empty artifact manifest')
    return digests


def verify_model(directory, expected):
    if not isinstance(expected, str) or not re.fullmatch(r'[0-9a-f]{64}', expected):
        raise ValueError('Expected artifact identity must be a lowercase SHA-256')
    manifest = json.loads((directory / 'manifest.json').read_text())
    if (not isinstance(manifest, dict) or type(manifest.get('schema_version')) is not int
            or manifest['schema_version'] != 1):
        raise ValueError('Expected model manifest schema_version 1')
    if manifest.get('aggregate_sha256') != expected:
        raise ValueError('Model manifest identity differs from requested artifact')
    digests = verify_files(directory, manifest['files'])
    if type(manifest.get('file_count')) is not int or manifest['file_count'] != len(digests):
        raise ValueError('Model manifest file count mismatch')
    if (type(manifest.get('total_size_bytes')) is not int or manifest['total_size_bytes']
            != sum(entry['size_bytes'] for entry in manifest['files'])):
        raise ValueError('Model manifest total size mismatch')
    aggregate = hashlib.sha256(b''.join(
        bytes.fromhex(digests[name]) for name in sorted(digests)
    )).hexdigest()
    if aggregate != expected:
        raise ValueError('Model content aggregate differs from requested artifact')
    return aggregate
