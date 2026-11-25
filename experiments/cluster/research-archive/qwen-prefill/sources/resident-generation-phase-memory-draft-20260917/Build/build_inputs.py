"""Exact private native-build inputs; no compiler, model or remote operations."""
from pathlib import Path
import hashlib
import json
import os

BASE = Path(__file__).resolve().parent
OLD = BASE.parent.parent / 'resident-generation-phase-native-draft-20260916' / 'Build'
DRAFT = BASE.parent
WORK = OLD / 'workspace'
PACKAGE = WORK / 'libs/darkbloom-cluster-worker'
CACHE = PACKAGE / '.build-native-worker'
METALLIB_SHA = '2129f6132794d84243c02631bc7478417dba0e0dbd10467beab56c11bf20bdd2'
PINS = {
    OLD / 'source-snapshot-1.json': '73e8aa6a1181ba088fa29ca3a41ebbd099ecffb0b6436ba1e52846e298b6eaf0',
    OLD / 'dependency-snapshot-1.json': '7ea139cc8956703eda9b5baefe9ca072dd461bf51fb14f265fa834861aeb71ee',
    OLD / 'runtime-bundle-1/bundle.json': '276e493502a0cfe94aa7264ffdf7a4d0d0d035187ed0526dbd57965c6b51da54',
}



def sha(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        while block := stream.read(1024 * 1024):
            value.update(block)
    return value.hexdigest()


def relative(value):
    path = Path(value)
    if path.is_absolute() or '..' in path.parts:
        raise ValueError('Expected bounded relative source path')
    return path


def snapshot(root):
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


def authority():
    for path, expected in PINS.items():
        if sha(path) != expected:
            raise RuntimeError('Inherited phase6495 authority changed: ' + str(path))
    for row in json.loads((DRAFT / 'manifest.json').read_bytes())['members']:
        path = DRAFT / relative(row['path'])
        if path.stat().st_size != row['bytes'] or sha(path) != row['sha256']:
            raise RuntimeError('Frozen phase-memory source changed: ' + row['path'])
    sources = json.loads((OLD / 'source-snapshot-1.json').read_bytes())['members']
    dependencies = json.loads((OLD / 'dependency-snapshot-1.json').read_bytes())['members']
    if len(sources) != 3050 or len(dependencies) != 8755:
        raise RuntimeError('Unexpected phase6495 source closure')
    return sources, dependencies


def verify():
    sources, dependencies = authority()
    old_cache = OLD / 'workspace/libs/darkbloom-cluster-worker/.build-native-worker'
    if snapshot(old_cache / 'checkouts') != dependencies:
        raise RuntimeError('Qualified dependency sources changed')
    expected = {row['path']: dict(row) for row in sources}
    changed = []
    for overlay in sorted((DRAFT / 'proposed').rglob('*.swift')):
        rel = str(overlay.relative_to(DRAFT / 'proposed'))
        expected[rel] = dict(path=rel, bytes=overlay.stat().st_size, sha256=sha(overlay))
        changed.append(rel)
    expected = sorted(expected.values(), key=lambda row: row['path'])
    if snapshot(WORK) != expected or snapshot(CACHE / 'checkouts') != dependencies:
        raise RuntimeError('Prepared phase-memory source/dependency closure differs')
    return dict(sourceMembers=len(expected), dependencyMembers=len(dependencies),
        changedSourcePaths=changed, exactOverlayAndDependenciesVerified=True)
