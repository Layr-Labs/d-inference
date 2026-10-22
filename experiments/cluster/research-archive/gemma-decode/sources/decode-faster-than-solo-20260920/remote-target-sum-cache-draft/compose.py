#!/usr/bin/env python3
"""Verify source union; only explicit --apply changes the named disposable workspace."""
import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent

def digest(data):
    return hashlib.sha256(data).hexdigest()

def pin(path):
    data = path.read_bytes()
    return dict(path=str(path),bytes=len(data),sha256=digest(data))

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

def check():
    own = json.loads((ROOT/'source-inputs.json').read_text())
    for row in own['members']:
        read_pin(row,ROOT)
    spec = json.loads((ROOT/'integration.json').read_text())
    base = json.loads(read_pin(spec['baseSources']))
    for authority in spec['authorities']:
        read_pin(authority)
    current = {row['path']:row for row in base['files']}
    if len(current) != 121 or len(base['files']) != 121:
        raise ValueError('base closure differs')
    for layer in spec['layers']:
        seen = set()
        for row in layer['files']:
            target = row['target']
            if target in seen or current.get(target) != row['before']:
                raise ValueError(f'layer/preimage mismatch: {target}')
            seen.add(target)
            read_pin(row['source'])
            current[target] = dict(path=target,bytes=row['source']['bytes'],sha256=row['source']['sha256'])
    expected = json.loads((ROOT/'expected-sources.json').read_text())['files']
    if len(expected) != 121 or [current[key] for key in sorted(current)] != expected:
        raise ValueError('projected source closure differs')
    initial = {row['path']:row for row in base['files']}
    changed = {row['target']:row for row in spec['changes']}
    if len(changed) != len(spec['changes']):
        raise ValueError('duplicate final target')
    if set(changed) != {key for key in current if current[key] != initial.get(key)}:
        raise ValueError('final change set differs')
    for target,row in changed.items():
        if row['before'] != initial.get(target):
            raise ValueError('final preimage differs')
        read_pin(row['source'])
        if current[target] != dict(path=target,bytes=row['source']['bytes'],sha256=row['source']['sha256']):
            raise ValueError('final source differs')
    prior = (ROOT/'preimages/Gemma4MTPRemoteTargetResources.swift').read_text()
    oracle = prior.replace('Gemma4MTPRemoteTargetReceipt','UncachedRemoteTargetReceipt').replace(
        'Gemma4MTPRemoteTargetResources','UncachedRemoteTargetResources')
    if oracle != (ROOT/'Tests/UncachedRemoteTargetResources.swift').read_text():
        raise ValueError('CPU uncached oracle differs from exact predecessor')
    return spec,base,expected

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--apply',action='store_true')
    parser.add_argument('--output',type=Path)
    args = parser.parse_args()
    spec,base,expected = check()
    if not args.apply:
        if args.output is not None:
            parser.error('--output requires --apply')
        print(json.dumps(dict(sourceOnly=True,changes=len(spec['changes']),sourceMembers=len(expected),
            manifest=pin(ROOT/'source-inputs.json'),expected=pin(ROOT/'expected-sources.json'))))
        return
    if args.output is None or not args.output.is_absolute():
        parser.error('--apply requires an absolute new output directory')
    workspace = Path(spec['workspace'])
    if str(workspace.resolve()) != spec['workspace'] or base['workspace'] != spec['workspace']:
        raise ValueError('workspace identity differs')
    # Validate all finite base sources and every new-path absence before writes.
    for row in base['files']:
        read_pin(row,workspace)
    for row in spec['changes']:
        target = workspace/row['target']
        if row['before'] is None and (target.exists() or target.is_symlink()):
            raise ValueError(f'new source already exists: {target}')
        if target.parent.resolve() != target.parent:
            raise ValueError('noncanonical target parent')
    output = args.output
    if output.parent.resolve() != output.parent:
        raise ValueError('noncanonical output parent')
    output.mkdir(exist_ok=False)
    for name in ['before','after']:
        (output/name).mkdir()
    for row in spec['changes']:
        for name,record,relative in [('before',row['before'],workspace),('after',row['source'],None)]:
            if record is not None:
                copy = output/name/row['target']; copy.parent.mkdir(parents=True,exist_ok=True)
                copy.write_bytes(read_pin(record,relative))
    for row in spec['changes']:
        target = workspace/row['target']
        if row['before'] is None:
            with target.open('xb') as stream:
                stream.write(read_pin(row['source']))
        else:
            read_pin(row['before'],workspace)
            target.write_bytes(read_pin(row['source']))
    for row in expected:
        read_pin(row,workspace)
    result = dict(base)
    result.update(spec['sourceFields'])
    result.update(files=expected,workspaceMutated=True,compilerExecuted=False,
        remoteTargetSumCacheBaseSources=spec['baseSources'],
        remoteTargetSumCacheSourceManifestSHA256=pin(ROOT/'source-inputs.json')['sha256'],
        remoteTargetSumCacheIntegrationSHA256=pin(ROOT/'integration.json')['sha256'],
        remoteTargetSumCacheChanges=spec['changes'])
    receipt = output/'sources.json'
    receipt.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(pin(receipt)))

if __name__ == '__main__':
    main()
