"""Small-file/source-only verification. Does not import harness or execute children."""
import ast
import difflib
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent


def read(path, maximum=4 * 1024**2):
    path = Path(path)
    assert path.is_file() and not path.is_symlink() and path.stat().st_size <= maximum
    return path.read_bytes()


def sha(path):
    return hashlib.sha256(read(path)).hexdigest()


def verify_rows(rows, root):
    seen = set()
    for row in rows:
        relative = Path(row['path'])
        assert not relative.is_absolute() and '..' not in relative.parts and row['path'] not in seen
        seen.add(row['path'])
        raw = read(root / relative)
        assert len(raw) == row['bytes'] and hashlib.sha256(raw).hexdigest() == row['sha256']


def check():
    native = json.loads(read(ROOT / 'native-manifest.json'))
    verify_rows(native['members'], ROOT)
    assert native['status'] == 'source-only-uncompiled' and len(native['members']) == 13
    context = json.loads(read(ROOT / 'context.json'))
    for row in context['predecessor'] + context['instructions']:
        assert sha(row['path']) == row['sha256']
    assert sha(context['knownHosts']['path']) == context['knownHosts']['sha256']
    base = Path(context['baseWorkspace'])
    verify_rows(context['exactNativeInputs'], base)
    snapshot = json.loads(read(context['predecessor'][0]['path']))['members']
    dependencies = json.loads(read(context['predecessor'][1]['path']))['members']
    assert len(snapshot) == 3081 and len(dependencies) == 9832
    before = {row['path']: row for row in snapshot}
    assert len(before) == 3081
    projected = dict(before)
    overlay = json.loads(read(ROOT / 'overlay.json'))
    assert overlay['baseWorkspace'] == str(base) and len(overlay['files']) == 8
    destinations = set()
    for row in overlay['files']:
        assert row['destination'] not in destinations
        destinations.add(row['destination'])
        raw = read(ROOT / row['source'])
        assert hashlib.sha256(raw).hexdigest() == row['sha256'] and len(raw) == row['bytes']
        old = before.get(row['destination'])
        assert (old['sha256'] if old else None) == row['preimageSHA256']
        projected[row['destination']] = dict(path=row['destination'], sha256=row['sha256'], bytes=row['bytes'])
    assert len(projected) == 3088
    assert json.loads(read(ROOT / 'expected-source.json'))['members'] == [projected[k] for k in sorted(projected)]
    package = 'libs/darkbloom-cluster-worker/Package.swift'
    assert sha(ROOT / 'Package.before.swift') == before[package]['sha256']
    difference = ''.join(difflib.unified_diff(
        read(ROOT / 'Package.before.swift').decode().splitlines(True),
        read(ROOT / 'Package.after.swift').decode().splitlines(True),
        fromfile='a/' + package, tofile='b/' + package))
    assert difference.encode() == read(ROOT / 'Package.patch')
    lineage = json.loads(read(ROOT / 'harness-lineage.json'))
    for row in lineage:
        assert sha(row['source']) == row['sha256']
        if row['unchangedCopy']:
            assert sha(ROOT / row['copy']) == row['sha256']
    operations = json.loads(read(ROOT / 'operations-inputs.json'))
    for row in operations['pins']:
        raw = read(row['path'])
        assert len(raw) == row['bytes'] and hashlib.sha256(raw).hexdigest() == row['sha256']
    manifest = json.loads(read(ROOT / 'manifest.json'))
    verify_rows(manifest['files'], ROOT)
    python = [row['path'] for row in manifest['files'] if row['path'].endswith('.py')]
    for name in python:
        ast.parse(read(ROOT / name).decode(), filename=name)
    return dict(status='source-checks-passed', nativeManifestSHA256=sha(ROOT / 'native-manifest.json'),
                frozenFiles=len(manifest['files']), nativeOverlayFiles=8, sourceFiles=3088,
                dependencyFiles=9832, unchangedNativeInputs=len(context['exactNativeInputs']),
                pythonASTFiles=len(python), sourceOnly=True, fixturesExecuted=False,
                compilerExecuted=False, remoteExecuted=False)


if __name__ == '__main__':
    print(json.dumps(check(), sort_keys=True))
