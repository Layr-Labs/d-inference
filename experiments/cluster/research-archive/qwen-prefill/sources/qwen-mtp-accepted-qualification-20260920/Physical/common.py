"""Small pinned-file and create-only helpers for the late-bound physical package."""
import hashlib
import json
from pathlib import Path
import os

BASE = Path(__file__).resolve().parent
REMOTE = '/Users/developer/DarkbloomDev/qwen-mtp-accepted-qualification-20260920'
RESEARCH = Path('/Users/developer/DarkbloomDev/cluster-research')
OWNER = RESEARCH / 'qwen-resident-mtp-probe-clean-rerun-20260915'
REFERENCE = RESEARCH / 'qwen9b-protected-ordinary-reference-draft-20260917'


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False).encode() + b'\n'


def sha(path):
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(1024*1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def write(path, raw, mode=0o600):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode)
    with os.fdopen(fd, 'wb') as out:
        out.write(raw); out.flush(); os.fsync(out.fileno())


def write_json(path, value):
    write(path, canonical(value))


def replace(text, old, new):
    if text.count(old) != 1:
        raise ValueError('Exact predecessor substitution differs: ' + old[:100])
    return text.replace(old, new)


def file_manifest(directory):
    files = []
    for path in sorted(directory.rglob('*')):
        if path.is_file() and path.name != 'manifest.json':
            files.append(dict(path=str(path.relative_to(directory)), bytes=path.stat().st_size, sha256=sha(path)))
    write_json(directory / 'manifest.json', dict(files=files))


def verify_sources():
    for name in ['manifest.json', 'template-lineage.json']:
        data = json.loads((BASE / name).read_bytes())
        for row in data['files']:
            path = BASE / row['path']
            if path.is_symlink() or path.stat().st_size != row['bytes'] or sha(path) != row['sha256']:
                raise ValueError('Physical source pin differs: ' + str(path))
    # All copied predecessors remain independently pinned; no payload/binary read.
    for row in json.loads((BASE / 'template-lineage.json').read_bytes())['files']:
        if sha(Path(row['source'])) != row['sha256']:
            raise ValueError('Qualified helper predecessor changed')


def verify_bound(directory, wanted):
    path = directory / 'binding-receipt.json'
    if sha(path) != wanted:
        raise ValueError('Exact prospective binding receipt differs')
    receipt = json.loads(path.read_bytes())
    if receipt['schema'] != 'qwen_mtp_short_binding_receipt_v1' or receipt['physicalSourceManifestSHA256'] != sha(BASE / 'manifest.json') or receipt['remoteRoot'] != REMOTE:
        raise ValueError('Bound physical source/root differs')
    for row in receipt['files']:
        path = directory / row['path']
        if path.is_symlink() or path.stat().st_size != row['bytes'] or sha(path) != row['sha256']:
            raise ValueError('Prospective generated source differs: ' + row['path'])
    return receipt


def local_execute(directory):
    import importlib.util
    import sys
    sys.path.insert(0, str(directory / 'reference/package'))
    spec = importlib.util.spec_from_file_location('qualified_local_process', directory / 'reference/local_process.py')
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module.execute
