"""Read-only pin and metadata checks; never starts a compiler or native code."""
import ast
import hashlib
import importlib.util
import json
from pathlib import Path

BASE = Path(__file__).resolve().parent


def pin(path):
    raw = path.read_bytes()
    return {'path': str(path), 'sizeBytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest()}


def verify():
    inputs = json.loads((BASE / 'inputs.json').read_text())
    for row in inputs['files']:
        if pin(Path(row['path'])) != row:
            raise ValueError('Pinned input changed: ' + row['path'])
    manifest = json.loads((BASE / 'manifest.json').read_text())
    for row in manifest['members']:
        actual = pin(BASE / row['path'])
        if (actual['sizeBytes'], actual['sha256']) != (row['bytes'], row['sha256']):
            raise ValueError('Correction changed: ' + row['path'])
    for path in [BASE / 'verify.py', BASE / 'run.py']:
        ast.parse(path.read_text(), filename=str(path))
    return inputs


def main():
    value = verify()
    resource = Path(value['resourceDraft'])
    spec = importlib.util.spec_from_file_location('frozen_gemma_ledger', resource / 'derive_ledger.py')
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    ledger = module.derive()
    if ledger != json.loads((resource / 'ledger.json').read_text()):
        raise ValueError('Independent ledger changed')
    row = ledger['targets']['full-reference']
    casts = [item for item in row['namedArrays'] if item['name'].startswith(('constantCast:', 'headCast:'))]
    if len(casts) != 652 or sum(item['bytes'] for item in casts) != 3_154_055_168:
        raise ValueError('Observed missing-cast diagnosis differs')
    if row['namedArrayCount'] - len(casts) != 1912 or row['namedLogicalBytes'] - sum(item['bytes'] for item in casts) != 1_658_991_464:
        raise ValueError('Independent cast subtraction does not reproduce actual failure')
    print(json.dumps({'passed': True, 'inputPins': len(value['files']),
        'independentLedgerUnchanged': True, 'actualFailureReproducedByMissingCasts': True,
        'compilerOrNativeExecuted': False, 'payloadRead': False}, sort_keys=True))


if __name__ == '__main__':
    main()
