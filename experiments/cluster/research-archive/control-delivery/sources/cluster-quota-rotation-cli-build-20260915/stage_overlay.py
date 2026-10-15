"""Apply only the frozen CLI delta after a root slot grant; no compiler here."""
import hashlib
import importlib.util
import json
from pathlib import Path
import sys

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def inputs():
    values = json.loads((HERE / 'inputs.json').read_text())
    for helper in values['helpers']:
        if digest(Path(helper['path'])) != helper['sha256']:
            raise ValueError('Pinned runner/inventory helper differs')
    spec = importlib.util.spec_from_file_location('source_inventory', values['helpers'][0]['path'])
    inventory = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(inventory)
    return values, inventory


def main():
    values, source = inputs()
    workspace, package = Path(values['workspace']), Path(values['package'])
    before_path = Path(values['baseSnapshot'])
    if digest(before_path) != values['baseSnapshotSHA256']:
        raise ValueError('Qualified source snapshot differs')
    before = json.loads(before_path.read_text())
    if source.inventory(workspace) != before:
        raise ValueError('Qualified workspace source/dependencies changed')
    if digest(package / 'manifest.json') != values['packageManifestSHA256']:
        raise ValueError('Frozen CLI source manifest differs')
    for row in json.loads((package / 'manifest.json').read_text())['files']:
        if digest(package / row['path']) != row['sha256']:
            raise ValueError('Frozen CLI member differs')
    for row in values['files']:
        path = workspace / row['path']
        if row['beforeSHA256'] is None:
            if path.exists() or path.is_symlink():
                raise ValueError('New destination is occupied')
        elif path.is_symlink() or digest(path) != row['beforeSHA256']:
            raise ValueError('CLI preimage differs')
    output = HERE / 'staged'
    output.mkdir(mode=0o700, exist_ok=False)
    after = dict(before)
    for row in values['files']:
        path = workspace / row['path']
        payload = (package / 'proposed' / row['path']).read_bytes()
        if hashlib.sha256(payload).hexdigest() != row['afterSHA256']:
            raise ValueError('Proposed bytes differ')
        if row['beforeSHA256'] is not None:
            saved = output / 'originals' / row['path']
            saved.parent.mkdir(parents=True, exist_ok=True)
            saved.write_bytes(path.read_bytes())
            path.write_bytes(payload)
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            with path.open('xb') as stream:
                stream.write(payload)
        after[row['path']] = {'sha256': row['afterSHA256']}
    if source.inventory(workspace) != after:
        raise ValueError('Post-stage source inventory differs from exact three-file delta')
    for row in values['controls']:
        if digest(workspace / row['path']) != row['sha256']:
            raise ValueError('Unchanged integration control differs')
    (output / 'source-snapshot.json').write_text(json.dumps(after, indent=2, sort_keys=True) + '\n')
    (output / 'receipt.json').write_text(json.dumps({'passed': True, 'changedFiles': values['files'],
        'sourceDependencyCount': len(after), 'mainMutated': False, 'compilerExecuted': False}, indent=2) + '\n')
    print('Staged exact CLI delta; source/dependency count ' + str(len(after)), flush=True)


if __name__ == '__main__':
    main()
