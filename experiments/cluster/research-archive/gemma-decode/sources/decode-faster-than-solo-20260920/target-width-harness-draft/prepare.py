"""Root-only create-only small source composition; no binary, model, process or remote action."""
import argparse
import ast
import hashlib
import json
from pathlib import Path

ROOT=Path(__file__).resolve().parent
BASE=ROOT.parent/'harness-local-mtp-v2'
BASE_SHA='09bbc730b3fcbe8440fbe9069428901a5f3a2f1865cda75dbfcadcb3c454aa58'
OMIT={'freeze.py','required-native-sources.template.json'}

def raw(path):
    assert path.is_file() and not path.is_symlink() and path.stat().st_size<=2*1024**2,str(path)
    return path.read_bytes()
def sha(data):return hashlib.sha256(data).hexdigest()
def verify():
    frozen=json.loads(raw(ROOT/'source-inputs.json'))
    for row in frozen['members']:
        data=raw(ROOT/row['path']);assert len(data)==row['bytes'] and sha(data)==row['sha256'],row['path']
    base_raw=raw(BASE/'source-inputs.json');assert sha(base_raw)==BASE_SHA
    members=json.loads(base_raw)['members'];assert len(members)==38
    projected={}
    for row in members:
        path=Path(row['path']);assert not path.is_absolute() and '..' not in path.parts
        data=raw(BASE/path);assert len(data)==row['bytes'] and sha(data)==row['sha256'],row['path']
        if row['path'] not in OMIT:projected[row['path']]=data
    for row in frozen['members']:
        if row['path'].startswith('proposed/'):
            name=row['path'][9:];assert name and name not in OMIT
            projected[name]=raw(ROOT/row['path'])
    for name,data in projected.items():
        if name.endswith('.py'):ast.parse(data,name)
    required=json.loads(projected['required-native-sources.json'])
    for key in ('actualBuildReceipt','actualSources'):
        row=required[key];assert sha(raw(Path(row['path'])))==row['sha256']
    build=json.loads(raw(Path(required['actualBuildReceipt']['path'])))
    source=json.loads(raw(Path(required['actualSources']['path'])))
    assert build['status']=='passed' and build['exitCode']==0 and build['compilerReaped'] is True and build['groupAbsent'] is True
    assert build['gpuExecuted'] is False and build['sourcesSHA256']==required['actualSources']['sha256']
    assert (build['nativeSHA256'],build['nativeBytes'])==(required['nativeSHA256'],required['nativeBytes'])
    assert source['files']==required['requiredFiles'] and source['compositionSourceManifestSHA256']==required['compositionSourceManifestSHA256']
    assert set(source['options'])=={'targetWidth','smallQMV'}
    return projected

def main():
    p=argparse.ArgumentParser(allow_abbrev=False)
    g=p.add_mutually_exclusive_group(required=True);g.add_argument('--check',action='store_true');g.add_argument('--output',type=Path)
    a=p.parse_args();projected=verify()
    if a.check:
        print(json.dumps(dict(status='source-checked',baseMembers=38,projectedMembers=len(projected),materialized=False,binaryHashed=False)))
        return
    target=a.output
    assert target==ROOT.parent/'harness-target-width-v1' and target.parent.resolve()==target.parent and not target.exists()
    target.mkdir(mode=0o700)
    members=[]
    for name,data in sorted(projected.items()):
        path=target/name;path.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
        with path.open('xb') as stream:stream.write(data)
        members.append(dict(path=name,bytes=len(data),sha256=sha(data)))
    provenance=dict(schema='gemma4_target_width_harness_preparation_v1',
        originalSourceManifestSHA256=BASE_SHA,draftSourceManifestSHA256=sha(raw(ROOT/'source-inputs.json')),
        omittedUnusedPredecessorFiles=sorted(OMIT),nativeIdentityLateVerifiedByOriginalActivation=True,
        physicalExecuted=False,compilerExecuted=False)
    data=(json.dumps(provenance,indent=2)+'\n').encode()
    with (target/'target-width-provenance.json').open('xb') as stream:stream.write(data)
    members.append(dict(path='target-width-provenance.json',bytes=len(data),sha256=sha(data)))
    value=dict(schema='gemma4_local_mtp_harness_sources_v1',members=sorted(members,key=lambda x:x['path']))
    with (target/'source-inputs.json').open('x') as stream:json.dump(value,stream,indent=2);stream.write('\n')
    print(json.dumps(dict(status='source-prepared',output=str(target),sourceSHA256=sha(raw(target/'source-inputs.json')),members=len(members))))

if __name__=='__main__':main()
