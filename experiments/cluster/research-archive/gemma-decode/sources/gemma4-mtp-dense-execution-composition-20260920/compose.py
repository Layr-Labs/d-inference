#!/usr/bin/env python3
"""Check the immutable union; only --apply mutates the named disposable workspace."""
import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent

def digest(data):
    return hashlib.sha256(data).hexdigest()

def read_pin(row, base=None):
    path = Path(row['path'])
    if not path.is_absolute():
        if base is None or '..' in path.parts:
            raise ValueError('invalid relative pin')
        path = base / path
    if path.is_symlink() or not path.is_file():
        raise ValueError(f'not a regular source: {path}')
    data = path.read_bytes()
    if len(data) != row['bytes'] or digest(data) != row['sha256']:
        raise ValueError(f'pin mismatch: {path}')
    return data

def pin(path):
    data = path.read_bytes()
    return dict(path=str(path), bytes=len(data), sha256=digest(data))

def replay(text, operations, reverse=False):
    for op in reversed(operations) if reverse else operations:
        old, new = (op['after'], op['before']) if reverse else (op['before'], op['after'])
        if text.count(old) != op['count']:
            raise ValueError('ambiguous merge operation')
        text = text.replace(old, new)
    return text

def check():
    own = json.loads((ROOT / 'source-inputs.json').read_text())
    for row in own['members']:
        read_pin(row, ROOT)
    spec = json.loads((ROOT / 'integration.json').read_text())
    base = json.loads(read_pin(spec['baseSources']))
    for parent in spec['sourceManifests']:
        manifest = json.loads(read_pin(parent))
        for row in manifest['members']:
            read_pin(row, Path(parent['path']).parent)
    for proof in json.loads((ROOT / 'merge-proof.json').read_text()):
        texts = {key: read_pin(proof[key]).decode() for key in ['base', 'activation', 'packed', 'combined']}
        if replay(texts['base'], proof['packedOperations']) != texts['packed']:
            raise ValueError('packed parent replay mismatch')
        if replay(texts['activation'], proof['packedOverActivationOperations']) != texts['combined']:
            raise ValueError('combined replay mismatch')
        if replay(texts['combined'], proof['packedOverActivationOperations'], True) != texts['activation']:
            raise ValueError('activation inverse mismatch')
        if 'activationOperations' in proof:
            if replay(texts['base'], proof['activationOperations']) != texts['activation']:
                raise ValueError('activation replay mismatch')
            if replay(texts['combined'], proof['activationOperations'], True) != texts['packed']:
                raise ValueError('packed inverse mismatch')
    current = {row['path']: row for row in base['files']}
    if len(current) != 116 or len(base['files']) != 116 or len(spec['changes']) != 15:
        raise ValueError('unexpected source closure')
    seen = set()
    for row in spec['changes']:
        target = row['target']
        if target in seen or current.get(target) != row['before']:
            raise ValueError('unexpected or duplicate source preimage')
        seen.add(target)
        read_pin(row['source'])
        current[target] = dict(path=target, bytes=row['source']['bytes'], sha256=row['source']['sha256'])
    expected = json.loads((ROOT / 'expected-sources.json').read_text())['files']
    if [current[key] for key in sorted(current)] != expected:
        raise ValueError('projected source union differs')
    return spec, base, expected

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    spec, base, expected = check()
    if not args.apply:
        if args.output is not None:
            parser.error('--output requires --apply')
        print(json.dumps(dict(sourceOnly=True, changes=15, sourceMembers=116,
            manifest=pin(ROOT / 'source-inputs.json'), expected=pin(ROOT / 'expected-sources.json'))))
        return
    if args.output is None or not args.output.is_absolute():
        parser.error('--apply requires an absolute, new --output directory')
    workspace = Path(spec['workspace'])
    if str(workspace.resolve()) != spec['workspace'] or base['workspace'] != spec['workspace']:
        raise ValueError('workspace identity differs')
    # Validate every source preimage before writing any workspace byte.
    for row in base['files']:
        read_pin(row, workspace)
    output = args.output
    output.mkdir(parents=True, exist_ok=False)
    for directory in ['before', 'after']:
        (output / directory).mkdir()
    for row in spec['changes']:
        target = Path(row['target'])
        before = output / 'before' / target
        after = output / 'after' / target
        before.parent.mkdir(parents=True, exist_ok=True)
        after.parent.mkdir(parents=True, exist_ok=True)
        before.write_bytes(read_pin(row['before'], workspace))
        after.write_bytes(read_pin(row['source']))
    for row in spec['changes']:
        path = workspace / row['target']
        read_pin(row['before'], workspace)
        path.write_bytes(read_pin(row['source']))
    for row in expected:
        read_pin(row, workspace)
    result = dict(base)
    result.update(spec['sourceFields'])
    result.update(files=expected, workspaceMutated=True, compilerExecuted=False,
        denseExecutionPredecessor=spec['baseSources'],
        denseExecutionCompositionManifestSHA256=pin(ROOT / 'source-inputs.json')['sha256'],
        denseExecutionIntegrationSHA256=pin(ROOT / 'integration.json')['sha256'],
        denseExecutionChanges=spec['changes'])
    receipt = output / 'sources.json'
    receipt.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(pin(receipt)))

if __name__ == '__main__':
    main()
