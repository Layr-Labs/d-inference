"""Exact private native-build inputs; no compiler, model or remote operations."""
from pathlib import Path
import hashlib
import json
import os

BASE = Path(__file__).resolve().parent
OLD = BASE.parent / 'qwen27b-owner-validation-build-20260915'
DRAFT = BASE.parent / 'qwen-resident-load-gate-diagnostics-draft-20260915'
WORK = BASE / 'workspace'
PACKAGE = WORK / 'libs/darkbloom-cluster-worker'
CACHE = PACKAGE / '.build-native-worker'
RELATIVE = 'libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime/QwenResidentLoading.swift'
METALLIB_SHA = '2129f6132794d84243c02631bc7478417dba0e0dbd10467beab56c11bf20bdd2'
PINS = {
    OLD / 'source-snapshot.json': '7a454fd5f44cbc292f0c64ae8e1dcf8c0b840803d346eb05ff06210bdf52522c',
    OLD / 'dependency-source-snapshot.json': 'fef0e26b91fe535f1ab2726499c7417c94c1b4e134daf49ef29bc240e2f9c103',
    OLD / 'handoff/manifest.json': 'd7d651af553e10d0d1fcb733d2c3ccf6a8597bcb89421c268f02424e7ad68cc1',
    DRAFT / 'manifest.json': '7e9da61684fa179cca8e23868225d5e25c12e9c88a5ac78f59e2f9d7b70ab0c4',
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
    for row in json.loads((DRAFT / 'manifest.json').read_bytes())['members']:
        path = DRAFT / relative(row['path'])
        if path.stat().st_size != row['bytes'] or sha(path) != row['sha256']:
            raise RuntimeError('Frozen diagnostic member changed: ' + str(path))
    sources = json.loads((OLD / 'source-snapshot.json').read_bytes())['members']
    dependencies = json.loads((OLD / 'dependency-source-snapshot.json').read_bytes())['members']
    if len(sources) != 3040 or len(dependencies) != 8755:
        raise RuntimeError('Unexpected inherited source closure')
    return sources, dependencies


def verify():
    sources, dependencies = authority()
    if snapshot(OLD / 'workspace') != sources:
        raise RuntimeError('Original a7c35 source snapshot changed')
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
