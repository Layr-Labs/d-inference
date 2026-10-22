"""Closed solo ancestor and overlay. Full source hashes run only after root grants preparation."""
from pathlib import Path
import hashlib
import json
import os

BASE = Path(__file__).resolve().parent
OLD = BASE.parent / 'qwen9b-resident-solo-generation-build-20260915'
DRAFT = BASE.parent / 'qwen27b-resident-solo-adapter-draft-20260915'
WORK = BASE / 'workspace'
PACKAGE = WORK / 'experiments/cluster/inference'
CACHE = PACKAGE / '.build'
FIXTURE = BASE.parent / 'qwen9b-resident-solo-generation-draft-20260915/Tests/retained-inputs.json'
PINS = {
    OLD / 'source-snapshot.json': 'f96c9fe3f5bb28ac83d5a48a4465771a79fd8691f8438d00af5aa2aed6d60760',
    OLD / 'build-1/dependency-source-pins.json': '674a65c405b10f2ddb25ecc3265de87bf8c28e2f571ef6711527dca37ca263f8',
    OLD / 'build-manifest.json': '796b0d89409e63445dc4baec18bc0e3baa989f82b1fe516f1a8fe79f33e4ceb9',
    OLD / 'bundle/bundle.json': '71617e2747ea993ad9012966997a7676442b9f0229c52989a2cebe2a21906cb7',
    DRAFT / 'manifest.json': '9420d783474bc1fe18ed905ed283395940d4096d9584343e14ad5f3889f21c80',
    FIXTURE: '1a7e2d74df5e055ec31c12478f49d1d07d1bb48cc64d150248859defb518cd25',
}


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def members(root):
    # Same dictionary convention as the qualified 8952 source snapshot.
    result = {}
    for directory, dirs, files in os.walk(root, followlinks=False):
        dirs[:] = sorted(x for x in dirs if x not in {'.git', '.build', '__pycache__'})
        for name in sorted(files):
            p = Path(directory) / name
            if name != '.git' and not p.is_symlink():
                result[str(p.relative_to(root))] = digest(p)
    return result


def authority():
    for path, expected in PINS.items():
        if path.is_symlink() or digest(path) != expected:
            raise ValueError('Frozen solo authority changed: ' + str(path))
    for name, row in json.loads((DRAFT / 'manifest.json').read_bytes())['files'].items():
        relative = Path(name)
        if relative.is_absolute() or '..' in relative.parts:
            raise ValueError('Invalid frozen overlay path')
        path = DRAFT / relative
        if path.is_symlink() or path.stat().st_size != row['bytes'] or digest(path) != row['sha256']:
            raise ValueError('Frozen solo overlay changed: ' + name)
    sources = json.loads((OLD / 'source-snapshot.json').read_bytes())
    deps = json.loads((OLD / 'build-1/dependency-source-pins.json').read_bytes())
    if len(sources) != 3290 or len(deps) != 9502:
        raise ValueError('Qualified solo source/dependency count differs')
    lineage = json.loads((DRAFT / 'lineage.json').read_bytes())
    expected = dict(sources)
    for relative in lineage['changedPaths']:
        if sources.get(relative) != lineage['originals'].get(relative):
            raise ValueError('Solo overlay base differs: ' + relative)
        expected[relative] = digest(DRAFT / 'proposed' / relative)
    if len(expected) != 3292:
        raise ValueError('Solo overlay must add only the two reviewed files')
    return sources, deps, expected, lineage['changedPaths']


def verify():
    sources, deps, expected, changed = authority()
    if members(OLD / 'workspace') != sources or members(OLD / 'workspace/experiments/cluster/inference/.build/checkouts') != deps:
        raise ValueError('Qualified solo ancestor sources changed')
    if members(WORK) != expected or members(CACHE / 'checkouts') != deps:
        raise ValueError('Prepared solo sources/dependencies differ')
    return dict(sourceMembers=len(expected), dependencyMembers=len(deps), changedSourcePaths=changed,
                ancestorSourceAndDependenciesUnchanged=True)


def verify_preparation():
    path = BASE / 'build-preparation-manifest.json'
    for row in json.loads(path.read_bytes())['members']:
        source = BASE / row['path']
        if source.is_symlink() or source.stat().st_size != row['bytes'] or digest(source) != row['sha256']:
            raise ValueError('Frozen build preparation changed: ' + row['path'])
    return digest(path)
