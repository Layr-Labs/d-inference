"""Pinned small authorities; full inventories run only during scheduled preparation/build."""
from pathlib import Path
import hashlib
import json
import os

BASE = Path(__file__).resolve().parent
INPUTS = json.loads((BASE / 'inputs.json').read_bytes())
SOURCE = Path(INPUTS['nativeSource'])
WORK = Path(INPUTS['workspace'])
SCRATCH = WORK / 'libs/darkbloom-cluster-worker/.build-native-worker'
RELEASE = SCRATCH / 'arm64-apple-macosx/release'
PRODUCT = 'LabAuthenticatedRDMABenchmark'


def sha(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        while block := stream.read(1024 * 1024):
            digest.update(block)
    return digest.hexdigest()


def pin(path):
    if path.is_symlink() or not path.is_file():
        raise ValueError('Expected regular file: ' + str(path))
    before = path.stat()
    value = dict(bytes=before.st_size, sha256=sha(path))
    after = path.stat()
    if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns):
        raise ValueError('File changed while hashing: ' + str(path))
    return value


def check(row, root=None):
    path = Path(row['path']) if root is None else root / row['path']
    if pin(path) != dict(bytes=row['bytes'], sha256=row['sha256']):
        raise ValueError('Pinned file changed: ' + str(path))


def write_json(path, value):
    with path.open('x') as out:
        json.dump(value, out, indent=2, sort_keys=True)
        out.write('\n')


def fresh(path):
    if not path.is_absolute() or path != path.resolve() or path.exists() or path.is_symlink():
        raise ValueError('Output must be fresh and canonical: ' + str(path))
    path.mkdir(mode=0o700)


def authorities():
    manifest = json.loads((BASE / 'manifest.json').read_bytes())
    if manifest['schema'] != 'lab_rdma_build_wrapper_v1':
        raise ValueError('Wrapper schema differs')
    for row in manifest['members']:
        check(row, BASE)
    for row in INPUTS['authorities'].values():
        check(row)
    native = json.loads((SOURCE / 'native-manifest.json').read_bytes())
    if (native['sourceCountBefore'], native['sourceCountAfter'], native['dependencyCount'], len(native['members'])) != (3081, 3088, 9832, 13):
        raise ValueError('Native source scope differs')
    for row in native['members']:
        check(row, SOURCE)
    for row in json.loads((SOURCE / 'context.json').read_bytes())['exactNativeInputs']:
        check(row, WORK)
    before = source_rows(False)
    by = {row['path']: row for row in before}
    overlay = json.loads((SOURCE / 'overlay.json').read_bytes())
    if overlay['baseWorkspace'] != str(WORK) or len(overlay['files']) != 8:
        raise ValueError('Overlay root or count differs')
    for row in overlay['files']:
        if by.get(row['destination'], {}).get('sha256') != row['preimageSHA256']:
            raise ValueError('Declared source preimage differs')
        by[row['destination']] = dict(path=row['destination'], bytes=row['bytes'], sha256=row['sha256'])
    if sorted(by.values(), key=lambda row: row['path']) != source_rows(True):
        raise ValueError('Expected 3088-source union differs')
    if len(before) != 3081 or len(by) != 3088 or len(dependency_rows()) != 9832:
        raise ValueError('Inventory count differs')
    old = json.loads(Path(INPUTS['authorities']['priorBuild']['path']).read_bytes())
    if old['status'] != 'passed' or old['binary'] != INPUTS['priorBinary']:
        raise ValueError('Qualified predecessor differs')


def source_rows(after):
    path = SOURCE / 'expected-source.json' if after else Path(INPUTS['authorities']['sourceBefore']['path'])
    return json.loads(path.read_bytes())['members']


def dependency_rows():
    return json.loads(Path(INPUTS['authorities']['dependencies']['path']).read_bytes())['members']


def entries(root):
    # Same inventory semantics as the native7 build_inputs.entries predecessor.
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
                row.update(pin(path))
            rows.append(row)
    return sorted(rows, key=lambda row: row['path'])


def inventory_check(after, output=None):
    authorities()
    sources, dependencies = entries(WORK), entries(SCRATCH / 'checkouts')
    if sources != source_rows(after) or dependencies != dependency_rows():
        raise ValueError('Exact source/dependency inventory changed; no new dependency is accepted')
    if output is not None:
        write_json(output / 'sources.json', dict(members=sources))
        write_json(output / 'dependencies.json', dict(members=dependencies))
    return dict(sourceCount=len(sources), dependencyCount=len(dependencies))


def resource_rows():
    bundle = Path(INPUTS['authorities']['priorBundle']['path']).parent
    return [dict(path=str(bundle / name), **value) for name, value in INPUTS['resources'].items()]


def save_receipt(path, value):
    # Only this process's create-only output directory is updated.
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')
