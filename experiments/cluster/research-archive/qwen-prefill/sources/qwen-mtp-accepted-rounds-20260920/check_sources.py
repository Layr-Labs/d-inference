"""Small source closure only. Does not scan/build the old workspace or cache."""
from pathlib import Path
import argparse
import ast
import difflib
import hashlib
import json

BASE = Path(__file__).resolve().parent


def read(path):
    if path.is_symlink() or not path.is_file():
        raise ValueError('Expected regular source: ' + str(path))
    return path.read_bytes()


def require_pin(path, value):
    data = read(path)
    if hashlib.sha256(data).hexdigest() != value['sha256']:
        raise ValueError('SHA differs: ' + str(path))
    if 'bytes' in value and len(data) != value['bytes']:
        raise ValueError('Size differs: ' + str(path))
    return data


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path)
    parser.add_argument('--require-manifest', action='store_true')
    args = parser.parse_args()
    lineage = json.loads(read(BASE / 'lineage.json'))
    old = Path(lineage['base'])
    for key in ['baseSourceSnapshot', 'baseDependencySnapshot', 'baseNativeBuildReceipt', 'nativeTailSourceManifest']:
        require_pin(Path(lineage[key]['path']), lineage[key])
    source = json.loads(read(Path(lineage['baseSourceSnapshot']['path'])))['members']
    source = {x['path']: x for x in source}
    if len(source) != 3075:
        raise ValueError('Unexpected base inventory')
    preimages = {x['path']: x for x in json.loads(read(BASE / 'preimages.json'))['files']}
    integration = json.loads(read(BASE / 'integration.json'))
    paths = [x['path'] for x in integration['files']]
    if len(paths) != 19 or len(paths) != len(set(paths)) or integration['base'] != str(old):
        raise ValueError('Overlay set/base differs')
    patch = []
    for value in integration['files']:
        name = value['path']
        if name.startswith('/') or '..' in Path(name).parts:
            raise ValueError('Unsafe overlay path')
        candidate = BASE / 'proposed' / name
        after = require_pin(candidate, value)
        if Path(value['sourcePath']) != candidate:
            raise ValueError('Overlay source binding differs')
        before = b''
        if value['beforeSHA256'] is None:
            if (old / name).exists() or name in source or (BASE / 'originals' / name).exists():
                raise ValueError('New overlay has an existing destination: ' + name)
        else:
            pin = preimages[name]
            if pin['sha256'] != value['beforeSHA256']:
                raise ValueError('Overlay preimage binding differs')
            before = require_pin(BASE / 'originals' / name, pin)
            if require_pin(old / name, pin) != before or source[name]['sha256'] != pin['sha256']:
                raise ValueError('Snapshot/source/original mismatch')
        patch.extend(difflib.unified_diff(before.decode().splitlines(keepends=True), after.decode().splitlines(keepends=True),
            fromfile='a/' + name if before else '/dev/null', tofile='b/' + name))
    if ''.join(patch).encode() != read(BASE / 'runtime.patch'):
        raise ValueError('Patch differs from exact originals/candidates')
    actual = {str(p.relative_to(BASE / 'proposed')) for p in (BASE / 'proposed').rglob('*') if p.is_file()}
    if actual != set(paths):
        raise ValueError('Unlisted proposed source')
    for entry in json.loads(read(BASE / 'source-delta.json')):
        before = read(BASE / 'originals' / entry['path']).decode().splitlines(keepends=True)
        after = read(BASE / 'proposed' / entry['path']).decode().splitlines(keepends=True)
        replay = list(before)
        for hunk in reversed(entry['hunks']):
            if ''.join(before[hunk['oldStart']:hunk['oldEnd']]) != hunk['old']:
                raise ValueError('Inverse source preimage differs')
            if ''.join(after[hunk['newStart']:hunk['newEnd']]) != hunk['new']:
                raise ValueError('Inverse source successor differs')
            replay[hunk['oldStart']:hunk['oldEnd']] = hunk['new'].splitlines(keepends=True)
        if replay != after:
            raise ValueError('Unlisted change outside source deltas')
    controls = json.loads(read(BASE / 'controls.json'))
    for value in controls:
        if value['path'] in paths or Path(value['sourcePath']) != old / value['path']:
            raise ValueError('Control overlaps or changes base')
        require_pin(Path(value['sourcePath']), value)
        if source[value['path']]['sha256'] != value['sha256']:
            raise ValueError('Control differs from qualified source snapshot')
    for value in lineage['exactTailOverlay']:
        require_pin(Path(value['sourcePath']), value)
        require_pin(BASE / 'proposed' / value['path'], value)
    inputs = json.loads(read(BASE / 'Tests/inputs.json'))
    for value in inputs:
        require_pin(Path(value['path']), value)
    command = json.loads(read(BASE / 'Tests/compile-command.json'))
    if [x for x in command if x.endswith('.swift')] != [x['path'] for x in inputs] or len(inputs) != 27:
        raise ValueError('Foundation input command differs')
    expected = json.loads(read(BASE / 'Tests/expected-checks.json'))
    if len(expected) != 26 or len(set(expected)) != 26:
        raise ValueError('Foundation coverage differs')
    helper = json.loads(read(BASE / 'Tests/helper-lineage.json'))
    require_pin(Path(helper['path']), helper)
    require_pin(BASE / 'Tests/owned_process.py', helper)
    for value in json.loads(read(BASE / 'audit-inputs.json')):
        require_pin(Path(value['path']), value)
    for p in BASE.rglob('*.py'):
        ast.parse(read(p), filename=str(p))
    manifest = BASE / 'manifest.json'
    members = None
    if manifest.exists():
        values = json.loads(read(manifest))['members']
        members = len(values)
        for value in values:
            require_pin(BASE / value['path'], value)
    elif args.require_manifest:
        raise ValueError('Frozen manifest missing')
    result = dict(status='passed', scope='selected source and metadata only', overlays=len(paths),
        modified=10, new=9, unchangedControls=len(controls), exactTailFiles=4,
        foundationInputs=len(inputs), stagedFoundationChecks=len(expected), frozenMembers=members,
        compilerExecuted=False, fixtureExecuted=False, modelExecuted=False, remoteExecuted=False,
        completeOldWorkspaceOrCacheRehashed=False)
    encoded = json.dumps(result, indent=2, sort_keys=True) + '\n'
    if args.output:
        with args.output.open('x') as out:
            out.write(encoded)
    print(encoded, end='')


if __name__ == '__main__':
    main()
