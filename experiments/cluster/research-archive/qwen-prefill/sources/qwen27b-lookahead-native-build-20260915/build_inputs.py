"""Exact private native-build inputs; no compiler, model or remote operations."""
from pathlib import Path
import hashlib
import json
import os

BASE = Path(__file__).resolve().parent
OLD = BASE.parent / 'qwen27b-resident-load-diagnostics-build-20260915'
DRAFT = BASE.parent / 'qwen27b-lookahead-worker-policy-draft-20260915'
WORK = BASE / 'workspace'
PACKAGE = WORK / 'libs/darkbloom-cluster-worker'
CACHE = PACKAGE / '.build-native-worker'
RELATIVE = 'libs/darkbloom-cluster-worker/Sources/DarkbloomClusterWorker/NativeWorkerRuntime.swift'
METALLIB_SHA = '2129f6132794d84243c02631bc7478417dba0e0dbd10467beab56c11bf20bdd2'
PINS = {
    OLD / 'source-snapshot-1.json': '5be25fe2c77f77c223c4277adc0a91a5e671c0f3dec63971992b1a858b138670',
    OLD / 'dependency-snapshot-1.json': '1f406bb65dd909a99a09e826c27c9d8fcb2ede66ae332358f0cf80f325cab903',
    OLD / 'runtime-bundle-1/bundle.json': '44ca36d0366501b78fe1e150bd9b5849988335cb0980bfc8cc9989d4b56b2536',
    DRAFT / 'manifest.json': 'f435cb249e71a19f3732dfa9d574e233ea149af60bd5ff1db8e562c17c50a740',
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
            raise RuntimeError('Authority changed: ' + str(path))
    for row in json.loads((DRAFT / 'manifest.json').read_bytes())['files']:
        path = DRAFT / relative(row['path'])
        if path.stat().st_size != row['bytes'] or sha(path) != row['sha256']:
            raise RuntimeError('Frozen diagnostic member changed: ' + str(path))
    sources = json.loads((OLD / 'source-snapshot-1.json').read_bytes())['members']
    dependencies = json.loads((OLD / 'dependency-snapshot-1.json').read_bytes())['members']
    if len(sources) != 3040 or len(dependencies) != 8755:
        raise RuntimeError('Unexpected inherited source closure')
    return sources, dependencies


def verify():
    sources, dependencies = authority()
    if snapshot(OLD / 'workspace') != sources:
        raise RuntimeError('Original 989f source snapshot changed')
    old_cache = OLD / 'workspace/libs/darkbloom-cluster-worker/.build-native-worker'
    if snapshot(old_cache / 'checkouts') != dependencies:
        raise RuntimeError('Original dependency sources changed')
    expected = [dict(row) for row in sources]
    overlay = DRAFT / 'proposed' / RELATIVE
    for row in expected:
        if row['path'] == RELATIVE:
            row.update(bytes=overlay.stat().st_size, sha256=sha(overlay))
    if snapshot(WORK) != expected or snapshot(CACHE / 'checkouts') != dependencies:
        raise RuntimeError('Prepared source/dependency closure differs')
    if (WORK / RELATIVE).read_bytes() != (BASE / 'overlay' / RELATIVE).read_bytes():
        raise RuntimeError('Prepared overlay differs from frozen copy')
    return dict(sourceMembers=len(expected), dependencyMembers=len(dependencies),
        changedSourcePaths=[RELATIVE], originalSourceAndDependenciesUnchanged=True)
