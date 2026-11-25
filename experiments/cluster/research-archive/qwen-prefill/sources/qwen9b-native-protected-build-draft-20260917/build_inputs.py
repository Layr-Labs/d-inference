"""Frozen native source + explicit fixture-only build composition."""
from pathlib import Path
import hashlib
import json
import os

BASE = Path(__file__).resolve().parent
WORKSPACE = BASE / 'workspace'
SCRATCH = WORKSPACE / 'libs/darkbloom-cluster-worker/.build-native-worker'


def sha(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        while block := stream.read(1024 * 1024):
            value.update(block)
    return value.hexdigest()


def relative(value):
    path = Path(value)
    if path.is_absolute() or '..' in path.parts or not path.parts:
        raise ValueError('Non-relative source path')
    return path


def frozen(directory, manifest_sha=None):
    manifest = directory / 'manifest.json'
    if manifest_sha is not None and sha(manifest) != manifest_sha:
        raise ValueError('Frozen manifest changed')
    rows = json.loads(manifest.read_bytes())['files']
    if len({x['path'] for x in rows}) != len(rows):
        raise ValueError('Duplicate frozen source path')
    for row in rows:
        path = directory / relative(row['path'])
        if path.is_symlink() or not path.is_file() or path.stat().st_size != row['bytes'] or sha(path) != row['sha256']:
            raise ValueError('Frozen source changed: ' + str(path))


def inputs():
    frozen(BASE)
    value = json.loads((BASE / 'lineage.json').read_bytes())
    old, candidate = Path(value['base']), Path(value['candidate'])
    frozen(candidate, value['candidateManifestSHA256'])
    if sha(candidate / 'native-build-composition.json') != value['sourceCompositionSHA256']:
        raise ValueError('Source composition changed')
    for path, digest in value['ancestryMetadata'].items():
        if sha(old / relative(path)) != digest:
            raise ValueError('Passed ancestry metadata changed')
    if json.loads((old / 'native-1/receipt.json').read_bytes()).get('status') != 'passed':
        raise ValueError('Passed native ancestor missing')
    for row in json.loads((BASE / 'helper-lineage.json').read_bytes()):
        if sha(BASE / row['destination']) != row['sha256']:
            raise ValueError('Copied owned/inventory helper changed')
    for row in json.loads((BASE / 'fixture-supplement.json').read_bytes()):
        if row.get('byteExact') and sha(Path(row['source'])) != row['sha256']:
            raise ValueError('Original capability fixture changed')
    retained = value['retainedFixture']
    if sha(Path(retained['path'])) != retained['sha256'] or Path(retained['path']).stat().st_size != retained['bytes']:
        raise ValueError('Retained Qwen test metadata changed')
    source = json.loads((old / 'source-snapshot-1.json').read_bytes())['members']
    integration = json.loads((BASE / 'integration.json').read_bytes())
    overlay, exclude = integration['files'], integration['exclude']
    if (len(source), len(overlay), len(exclude)) != (3060, 44, 7):
        raise ValueError('Unexpected reviewed source composition')
    by = {row['path']: row for row in source}
    if len(by) != len(source) or len({row['path'] for row in overlay}) != len(overlay):
        raise ValueError('Duplicate source or overlay path')
    for row in overlay:
        relative(row['path'])
        if by.get(row['path'], {}).get('sha256') != row['beforeSHA256']:
            raise ValueError('Ancestral overlay preimage differs')
        path = Path(row['source'])
        if path.is_symlink() or sha(path) != row['afterSHA256']:
            raise ValueError('Overlay source changed')
    for row in exclude:
        if by.get(row['path'], {}).get('sha256') != row['beforeSHA256']:
            raise ValueError('Explicit excluded source changed')
    effective = {row['path']: row.get('sha256') for row in source}
    effective.update({row['path']: row['afterSHA256'] for row in overlay})
    for row in exclude:
        effective.pop(row['path'])
    if len(effective) != value['expectedSourceCount'] or len(effective) != 3075:
        raise ValueError('Effective inventory count differs')
    for row in json.loads((BASE / 'controls.json').read_bytes())['files']:
        if effective.get(row['path']) != row['sha256']:
            raise ValueError('Source preservation control differs')
    return value, old, source, overlay, exclude


def checked(path, row):
    if 'symlink' in row:
        if not path.is_symlink() or os.readlink(path) != row['symlink']:
            raise ValueError('Ancestral source symlink changed')
        return None
    if path.is_symlink():
        raise ValueError('Regular source changed into symlink')
    raw = path.read_bytes()
    if len(raw) != row['bytes'] or hashlib.sha256(raw).hexdigest() != row['sha256']:
        raise ValueError('Changed source: ' + str(path))
    return raw


def entries(root):
    rows = []
    for current, directories, names in os.walk(root):
        directories[:] = sorted(x for x in directories if x not in {'.git', '__pycache__'} and not x.startswith('.build'))
        for name in sorted(names):
            if name in {'.git', '.DS_Store'}:
                continue
            path = Path(current) / name
            row = dict(path=str(path.relative_to(root)))
            if path.is_symlink():
                row['symlink'] = os.readlink(path)
            else:
                row.update(bytes=path.stat().st_size, sha256=sha(path))
            rows.append(row)
    return sorted(rows, key=lambda x: x['path'])
