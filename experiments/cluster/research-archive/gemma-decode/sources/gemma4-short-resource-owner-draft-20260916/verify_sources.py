"""Read only: exact small source pins, Python AST and retained metadata replay."""
import ast
import hashlib
import json
from pathlib import Path

BASE = Path(__file__).resolve().parent


def digest(path):
    raw = path.read_bytes()
    return len(raw), hashlib.sha256(raw).hexdigest()


def main():
    manifest = json.loads((BASE / 'manifest.json').read_text())
    for item in manifest['members']:
        if digest(BASE / item['path']) != (item['bytes'], item['sha256']):
            raise ValueError('Private source changed: ' + item['path'])
    controls = json.loads((BASE / 'source-controls.json').read_text())
    for item in controls['files']:
        if digest(Path(item['path'])) != (item['sizeBytes'], item['sha256']):
            raise ValueError('Selected dependency changed: ' + item['path'])
    for row in json.loads((BASE / 'integration.json').read_text())['overlay']:
        before = row['beforeSource']
        if before and digest(Path(before))[1] != row['beforeSHA256']:
            raise ValueError('Overlay preimage changed: ' + before)
        if Path(row['mainDestination']).exists():
            raise ValueError('New Runtime destination unexpectedly exists')
    for path in BASE.rglob('*.py'):
        ast.parse(path.read_text(), filename=str(path))
    # Only load the pinned pure metadata replay after verifying every member.
    import importlib.util
    spec = importlib.util.spec_from_file_location('gemma_short_metadata_replay', BASE / 'derive_ledger.py')
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    if module.derive() != json.loads((BASE / 'ledger.json').read_text()):
        raise ValueError('Retained allocation replay differs')
    print(json.dumps({'passed': True, 'privateMembers': len(manifest['members']),
        'selectedSourcePins': len(controls['files']), 'metadataReplay': True,
        'compilerOrNativeExecution': False, 'payloadRead': False}, sort_keys=True))


if __name__ == '__main__':
    main()
