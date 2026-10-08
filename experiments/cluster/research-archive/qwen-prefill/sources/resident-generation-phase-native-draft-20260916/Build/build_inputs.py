"""Exact private native-build inputs; no compiler, model or remote operations."""
from pathlib import Path
import hashlib
import json
import os

BASE = Path(__file__).resolve().parent
OLD = BASE.parent.parent / 'qwen27b-lookahead-native-build-20260915'
DRAFT = BASE.parent
WORK = BASE / 'workspace'
PACKAGE = WORK / 'libs/darkbloom-cluster-worker'
CACHE = PACKAGE / '.build-native-worker'
METALLIB_SHA = '2129f6132794d84243c02631bc7478417dba0e0dbd10467beab56c11bf20bdd2'
PINS = {
    OLD / 'source-snapshot-1.json': 'cb87b47034d647429b53a95acaa45f169ff35796290bdcc7f3ebb59eaf233e18',
    OLD / 'dependency-snapshot-1.json': '42aa7c5edffe7d6e151fa153353de8e3e36ef31538f229df093647d43268213a',
    OLD / 'runtime-bundle-1/bundle.json': 'c536b96ff4da7c1e4a6de1a8c945f263ddf91e72142a0f19f29ce398b2488f9c',
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
            raise RuntimeError('Inherited c35c authority changed: ' + str(path))
    for row in json.loads((DRAFT / 'manifest.json').read_bytes())['members']:
        path = DRAFT / relative(row['path'])
        if path.stat().st_size != row['bytes'] or sha(path) != row['sha256']:
            raise RuntimeError('Frozen phase source changed: ' + row['path'])
    sources = json.loads((OLD / 'source-snapshot-1.json').read_bytes())['members']
    dependencies = json.loads((OLD / 'dependency-snapshot-1.json').read_bytes())['members']
    if len(sources) != 3040 or len(dependencies) != 8755:
        raise RuntimeError('Unexpected c35c source closure')
    return sources, dependencies


def verify():
    sources, dependencies = authority()
    if snapshot(OLD / 'workspace') != sources:
        raise RuntimeError('Qualified c35c ancestor source changed')
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
        raise RuntimeError('Prepared phase source/dependency closure differs')
    return dict(sourceMembers=len(expected), dependencyMembers=len(dependencies),
        changedSourcePaths=changed, originalSourceAndDependenciesUnchanged=True)
