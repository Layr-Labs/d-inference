"""Exact input closure for the scheduled private same-cache build."""
from pathlib import Path
import hashlib
import json
import os

BASE = Path(__file__).resolve().parent
INPUTS = json.loads((BASE / 'inputs.json').read_bytes())
WORK = Path(INPUTS['workspace'])
SCRATCH = Path(INPUTS['scratch'])


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify_pin(value):
    path = Path(value['path'])
    if not path.is_file() or path.is_symlink() or path.stat().st_size != value['bytes'] or sha(path) != value['sha256']:
        raise ValueError('Source authority differs: ' + str(path))


def authorities():
    closure = json.loads((BASE / 'manifest.json').read_bytes())
    if closure['schema'] != 'qwen_mtp_same_source_build_wrapper_v1':
        raise ValueError('Build wrapper schema differs')
    for value in closure['members']:
        verify_pin(dict(value, path=str(BASE / value['path'])))
    for key in ['baseSource', 'baseDependencies', 'baseBuild', 'acceptedManifest', 'acceptedIntegration', 'referenceSnapshot', 'helper', 'referenceFixture']:
        verify_pin(INPUTS[key])
    accepted = Path(INPUTS['acceptedManifest']['path']).parent
    for value in json.loads((accepted / 'manifest.json').read_bytes())['members']:
        verify_pin(dict(value, path=str(accepted / value['path'])))
    if sha(BASE / 'owned_process.py') != INPUTS['helper']['sha256']:
        raise ValueError('Owned helper differs')
    original = BASE / 'reference-Package.original.swift'
    final = BASE / 'reference-Package.swift'
    if sha(original) != INPUTS['referencePackage']['beforeSHA256'] or sha(final) != INPUTS['referencePackage']['afterSHA256']:
        raise ValueError('Reference package path delta differs')
    resolved = BASE / 'reference-Package.resolved'
    worker_lock = WORK / 'libs/darkbloom-cluster-worker/Package.resolved'
    if sha(resolved) != INPUTS['referenceResolved']['afterSHA256'] or sha(worker_lock) != INPUTS['referenceResolved']['workerSHA256']:
        raise ValueError('Qualified same-revision lockfiles differ')
    if json.loads(resolved.read_bytes())['pins'] != json.loads(worker_lock.read_bytes())['pins']:
        raise ValueError('The two package roots must use identical dependency revisions')
    for name, wanted in INPUTS['referenceFiles'].items():
        source = Path(INPUTS['referenceBase']) / name
        if source.is_symlink() or sha(source) != wanted:
            raise ValueError('Reference source differs: ' + name)


def inventory(root):
    rows = []
    for directory, dirs, files in os.walk(root, followlinks=False):
        dirs[:] = sorted(x for x in dirs if x not in {'.git', '__pycache__'} and not x.startswith('.build'))
        for name in sorted(files):
            if name == '.git':
                continue
            path = Path(directory) / name
            if not path.is_file():
                raise ValueError('Non-regular source inventory entry')
            data = path.read_bytes()
            value = dict(path=str(path.relative_to(root)), bytes=len(data), sha256=hashlib.sha256(data).hexdigest())
            if path.is_symlink():
                value['symlink'] = str(path.readlink())
            rows.append(value)
    return sorted(rows, key=lambda x: x['path'])


def original_sources():
    return sorted(json.loads(Path(INPUTS['baseSource']['path']).read_bytes())['members'], key=lambda x: x['path'])


def original_dependencies():
    return sorted(json.loads(Path(INPUTS['baseDependencies']['path']).read_bytes())['members'], key=lambda x: x['path'])


def expected_sources():
    values = {x['path']: x for x in original_sources()}
    overlay = json.loads(Path(INPUTS['acceptedIntegration']['path']).read_bytes())['files']
    for x in overlay:
        values[x['path']] = dict(path=x['path'], bytes=x['bytes'], sha256=x['sha256'])
    for name, wanted in INPUTS['referenceFiles'].items():
        source = Path(INPUTS['referenceBase']) / name
        if name == INPUTS['referencePackage']['path']:
            source = BASE / 'reference-Package.swift'; wanted = INPUTS['referencePackage']['afterSHA256']
        elif name == INPUTS['referenceResolved']['path']:
            source = BASE / 'reference-Package.resolved'; wanted = INPUTS['referenceResolved']['afterSHA256']
        if name in values:
            raise ValueError('Reference package overlaps worker source')
        values[name] = dict(path=name, bytes=source.stat().st_size, sha256=wanted)
    return sorted(values.values(), key=lambda x: x['path'])


def verify_final():
    authorities()
    source = inventory(WORK)
    deps = inventory(SCRATCH / 'checkouts')
    if source != expected_sources() or deps != original_dependencies():
        raise ValueError('Final source or exact dependency closure changed')
    return dict(sourceCount=len(source), dependencyCount=len(deps))


def write_json(path, value):
    with path.open('x') as out:
        json.dump(value, out, indent=2, sort_keys=True); out.write('\n')
