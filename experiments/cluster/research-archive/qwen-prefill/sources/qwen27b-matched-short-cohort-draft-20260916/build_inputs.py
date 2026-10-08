"""Closed solo ancestor and overlay. Full source hashes run only after root grants preparation."""
from pathlib import Path
import hashlib
import json
import os

BASE = Path(__file__).resolve().parent
OLD = BASE.parent / 'qwen27b-resident-solo-build-20260915'
DRAFT = BASE
WORK = BASE / 'workspace'
PACKAGE = WORK / 'experiments/cluster/inference'
CACHE = PACKAGE / '.build'
FIXTURE = BASE.parent / 'qwen9b-resident-solo-generation-draft-20260915/Tests/retained-inputs.json'
PINS = {
    OLD / 'source-snapshot.json': '8c26272bebc672cbd08c3b734343a5b344c5f21877d111c2203d0a5b008706cc',
    OLD / 'dependency-source-snapshot.json': '674a65c405b10f2ddb25ecc3265de87bf8c28e2f571ef6711527dca37ca263f8',
    OLD / 'build-manifest-1.json': 'e75ab1e48acca086f5399aa3f512843723a1eed766734490cbbb4b74c6e36856',
    OLD / 'runtime-bundle-1/bundle.json': '71267928a25ea80289cbaf446d5fe231c8dfd1e75d67043ec8a8cfe415dadaa5',
    DRAFT / 'source-manifest.json': '20478022532885f77eb6acc662103f67a0a7ce17bd6051e14831cfa0b8906dcb',
    FIXTURE: '1a7e2d74df5e055ec31c12478f49d1d07d1bb48cc64d150248859defb518cd25',
}


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def members(root):
    # Same dictionary convention as the qualified 44495956 source snapshot.
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
    for name, row in json.loads((DRAFT / 'source-manifest.json').read_bytes())['files'].items():
        relative = Path(name)
        if relative.is_absolute() or '..' in relative.parts:
            raise ValueError('Invalid frozen overlay path')
        path = DRAFT / relative
        if path.is_symlink() or path.stat().st_size != row['bytes'] or digest(path) != row['sha256']:
            raise ValueError('Frozen solo overlay changed: ' + name)
    sources = json.loads((OLD / 'source-snapshot.json').read_bytes())
    deps = json.loads((OLD / 'dependency-source-snapshot.json').read_bytes())
    if len(sources) != 3292 or len(deps) != 9502:
        raise ValueError('Qualified solo source/dependency count differs')
    lineage = json.loads((DRAFT / 'lineage.json').read_bytes())
    expected = dict(sources)
    for relative in lineage['changedPaths']:
        if sources.get(relative) != lineage['originals'].get(relative):
            raise ValueError('Solo overlay base differs: ' + relative)
        expected[relative] = digest(DRAFT / 'proposed' / relative)
    if len(expected) != 3293:
        raise ValueError('Solo overlay must add only the one progress DTO file')
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
