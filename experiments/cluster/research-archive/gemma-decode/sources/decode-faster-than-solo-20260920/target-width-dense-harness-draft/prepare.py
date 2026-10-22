"""Create-only small source successor; actual build receipts are required to prepare."""
import argparse
import ast
import hashlib
import json
from pathlib import Path

ROOT=Path(__file__).resolve().parent
BASE=ROOT.parent/'harness-target-width-v1'
BASE_SHA='6f0678b9b24affa38fcec1f341e7ad9daf46e251dacd3d3fddafb154f872fddd'
OMIT={'required-native-sources.json','target-width-provenance.json'}

def raw(path):
    assert path.is_file() and not path.is_symlink() and path.stat().st_size<=2*1024**2,str(path)
    return path.read_bytes()
def sha(data):return hashlib.sha256(data).hexdigest()
def pin(path):return dict(path=str(path),sha256=sha(raw(path)))
def verify():
    frozen=json.loads(raw(ROOT/'source-inputs.json'))
    for row in frozen['members']:
        data=raw(ROOT/row['path']);assert len(data)==row['bytes'] and sha(data)==row['sha256'],row['path']
    base_raw=raw(BASE/'source-inputs.json');assert sha(base_raw)==BASE_SHA
    members=json.loads(base_raw)['members'];assert len(members)==42
    projected={}
    for row in members:
        name=row['path'];path=Path(name);assert not path.is_absolute() and '..' not in path.parts
        data=raw(BASE/path);assert len(data)==row['bytes'] and sha(data)==row['sha256'],name
        if name not in OMIT:projected[name]=data
    for row in frozen['members']:
        if row['path'].startswith('proposed/'):
            name=row['path'][9:];assert name and name not in OMIT
            projected[name]=raw(ROOT/row['path'])
    for name,data in projected.items():
        if name.endswith('.py'):ast.parse(data,name)
    spec=json.loads(raw(ROOT/'binding-spec.json'))
    for row in spec['sourcePackages']:
        assert sha(raw(Path(row['path'])))==row['sha256']
    template=json.loads(raw(ROOT/'required-native-sources.template.json'))
    assert len(template['requiredFiles'])==116
    assert len({x['path'] for x in template['requiredFiles']})==116
    assert sha(raw(Path(template['metadataSources']['path'])))==template['metadataSources']['sha256']
    return projected,spec,template

def actual_binding(build_path,sources_path,spec,template):
    assert all(p.is_absolute() and p.parent.resolve()==p.parent for p in (build_path,sources_path))
    assert pin(sources_path)==spec['actualAppliedSource'],'Exact corrected applied source receipt required'
    build=json.loads(raw(build_path));source=json.loads(raw(sources_path))
    assert build['status']=='passed' and build['exitCode']==0 and build['compilerReaped'] is True and build['groupAbsent'] is True
    assert build['gpuExecuted'] is False and build['sourcesSHA256']==sha(raw(sources_path))
    assert type(build['nativeSHA256']) is str and len(build['nativeSHA256'])==64
    assert all(x in '0123456789abcdef' for x in build['nativeSHA256']) and type(build['nativeBytes']) is int and 0<build['nativeBytes']<=200_000_000
    assert '--product' in build['argv'] and build['argv'][build['argv'].index('--product')+1]=='GemmaResidentBenchmark'
    assert source['files']==template['requiredFiles'] and source['workspaceMutated'] is True
    for key,wanted in spec['sourceFields'].items():assert source[key]==wanted,key
    assert source['memoPredecessor']['sha256']==spec['memoPredecessorSHA256']
    assert len(build['resources'])==2
    for actual,expected in zip(build['resources'],template['resources']):
        assert (actual['sha256'],actual['bytes'])==(expected['sha256'],expected['bytes'])
        assert actual['path'].endswith('/'+expected['path'].removeprefix('bundle/'))
    result=dict(template,actualBuildReceipt=pin(build_path),actualSources=pin(sources_path),
        nativeSHA256=build['nativeSHA256'],nativeBytes=build['nativeBytes'])
    return result

def main():
    p=argparse.ArgumentParser(allow_abbrev=False)
    g=p.add_mutually_exclusive_group(required=True);g.add_argument('--check',action='store_true');g.add_argument('--output',type=Path)
    p.add_argument('--build-receipt',type=Path);p.add_argument('--sources',type=Path)
    a=p.parse_args();projected,spec,template=verify()
    if a.check:
        assert a.build_receipt is None and a.sources is None
        print(json.dumps(dict(status='source-checked',baseMembers=42,projectedMembers=len(projected),requiredNativeSources=116,materialized=False,binaryHashed=False)))
        return
    assert a.build_receipt and a.sources,'Actual successful build/source receipts required'
    required=actual_binding(a.build_receipt,a.sources,spec,template)
    target=a.output
    assert target==ROOT.parent/'harness-target-width-dense-v1' and target.parent.resolve()==target.parent and not target.exists()
    projected['required-native-sources.json']=(json.dumps(required,indent=2)+'\n').encode()
    provenance=dict(schema='gemma4_target_width_dense_harness_preparation_v1',
        originalSourceManifestSHA256=BASE_SHA,draftSourceManifestSHA256=sha(raw(ROOT/'source-inputs.json')),
        omittedUnusedPredecessorFiles=sorted(OMIT),sourcePackages=spec['sourcePackages'],
        actualBuildReceipt=required['actualBuildReceipt'],actualSources=required['actualSources'],
        nativeOperation='qualify-mtp-target-width-dense',nativeIdentityLateVerifiedByOriginalActivation=True,
        physicalExecuted=False,compilerExecuted=False)
    projected['target-width-dense-provenance.json']=(json.dumps(provenance,indent=2)+'\n').encode()
    target.mkdir(mode=0o700);members=[]
    for name,data in sorted(projected.items()):
        path=target/name;path.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
        with path.open('xb') as stream:stream.write(data)
        members.append(dict(path=name,bytes=len(data),sha256=sha(data)))
    with (target/'source-inputs.json').open('x') as stream:
        json.dump(dict(schema='gemma4_local_mtp_harness_sources_v1',members=members),stream,indent=2);stream.write('\n')
    print(json.dumps(dict(status='source-prepared',output=str(target),sourceSHA256=sha(raw(target/'source-inputs.json')),members=len(members),nativeSHA256=required['nativeSHA256'])))
if __name__=='__main__':main()
