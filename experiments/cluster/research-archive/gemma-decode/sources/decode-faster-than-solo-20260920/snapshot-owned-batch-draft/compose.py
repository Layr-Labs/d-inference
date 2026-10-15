#!/usr/bin/env python3
"""Closed source-only checker and root-owned create-only application."""
import argparse, hashlib, json, os
from pathlib import Path

ROOT = Path(__file__).resolve().parent
PREFIX = 'libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime/'

def read(path):
    path = Path(path)
    if path.is_symlink() or not path.is_file(): raise ValueError('Missing or linked source: '+str(path))
    return path.read_bytes()
def digest(data): return hashlib.sha256(data).hexdigest()
def checked(row, relative=False):
    path = ROOT / row['path'] if relative else Path(row['path'])
    data = read(path)
    if len(data) != row['bytes'] or digest(data) != row['sha256']: raise ValueError('Pin mismatch: '+str(path))
    return data
def pin(path):
    data=read(path);return {'path':str(path),'bytes':len(data),'sha256':digest(data)}
def output(path,obj):
    path.parent.mkdir(parents=True,exist_ok=True)
    with path.open('x') as f: json.dump(obj,f,indent=2);f.write('\n')
def sources():
    manifest=json.loads(read(ROOT/'source-inputs.json'))
    for row in manifest['members']: checked(row,True)
    integration=json.loads(read(ROOT/'integration.json'))
    baseline=json.loads(checked(integration['baseSources']))
    original={r['path']:r for r in baseline['files']}
    expected=json.loads(checked(integration['expectedSources']))['files']
    projected=dict(original)
    if len(original)!=122 or len(expected)!=124: raise ValueError('Source cardinality differs')
    for change in integration['changes']:
        path=change['target']; before=change['before']; data=checked(change['source'])
        if not path.startswith(PREFIX) or original.get(path)!=before: raise ValueError('Preimage map differs')
        if before is not None:
            prior=read(ROOT/'Original'/Path(path).name)
            if len(prior)!=before['bytes'] or digest(prior)!=before['sha256']: raise ValueError('Preserved preimage differs')
        projected[path]={'path':path,'bytes':len(data),'sha256':digest(data)}
    if sorted(projected.values(),key=lambda r:r['path'])!=expected: raise ValueError('Projected source map differs')
    old=read(ROOT/'Original/CollectivePointToPoint.swift')
    if not read(ROOT/'Runtime/CollectivePointToPoint.swift').startswith(old+b'\n'): raise ValueError('Generic tensor implementation changed')
    for item in json.loads(read(ROOT/'transforms.json'))['files']:
        before=read(ROOT/'Original'/Path(item['target']).name).decode(); value=before
        for step in item['transforms']:
            if value.count(step['before'])!=1: raise ValueError('Ambiguous forward edit')
            value=value.replace(step['before'],step['after'])
        if value.encode()!=checked(item['after']): raise ValueError('Forward transform differs')
        for step in reversed(item['transforms']):
            if value.count(step['after'])!=1: raise ValueError('Ambiguous inverse edit')
            value=value.replace(step['after'],step['before'])
        if value!=before: raise ValueError('Inverse transform differs')
    return integration,baseline,expected

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--apply',action='store_true');parser.add_argument('--output',type=Path)
    args=parser.parse_args();integration,baseline,expected=sources()
    if not args.apply:
        if args.output: raise ValueError('--output requires --apply')
        print(json.dumps({'sourceChecksPassed':True,'overlays':14,'additions':2,'sources':124,'testsExecuted':False}));return
    if args.output is None: raise ValueError('Fresh --output is required')
    destination=args.output
    if not destination.is_absolute() or destination.exists() or destination.parent.resolve()!=destination.parent:
        raise ValueError('Output must be fresh under a canonical existing parent')
    workspace=Path(integration['workspace'])
    if workspace.resolve()!=workspace: raise ValueError('Workspace alias differs')
    # Full exact source closure before ANY mutation. No compiled cache or payload scan.
    for row in baseline['files']:
        data=read(workspace/row['path'])
        if len(data)!=row['bytes'] or digest(data)!=row['sha256']: raise ValueError('Workspace differs: '+row['path'])
    for change in integration['changes']:
        if change['before'] is None and (workspace/change['target']).exists(): raise ValueError('New source already exists')
    destination.mkdir(mode=0o700)
    output(destination/'before.json',baseline)
    for change in integration['changes']:
        target=workspace/change['target'];before=change['before'];data=checked(change['source'])
        if before is not None:
            prior=destination/'preimages'/change['target'];prior.parent.mkdir(parents=True,exist_ok=True)
            with prior.open('xb') as f:f.write(read(target))
        target.parent.mkdir(parents=True,exist_ok=True)
        temporary=target.with_name(target.name+'.owned-snapshot-source-tmp')
        with temporary.open('xb') as f:f.write(data)
        os.replace(temporary,target)
    for row in expected:
        data=read(workspace/row['path'])
        if len(data)!=row['bytes'] or digest(data)!=row['sha256']: raise ValueError('Postimage differs: '+row['path'])
    receipt=dict(baseline);receipt['files']=expected
    receipt['ownedSnapshotBatchPredecessor']=integration['baseSources']
    receipt['ownedSnapshotBatchManifestSHA256']=pin(ROOT/'source-inputs.json')['sha256']
    receipt['ownedSnapshotBatchIntegrationSHA256']=pin(ROOT/'integration.json')['sha256']
    receipt['ownedSnapshotBatchPolicy']=integration['policy']
    receipt['ownedSnapshotBatchChanges']=integration['changes']
    output(destination/'sources.json',receipt)
    print(json.dumps({'sourceApplicationPassed':True,'receipt':pin(destination/'sources.json'),'nativeExecution':False}))
if __name__=='__main__':main()
