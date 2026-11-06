"""Create-only source successor. Requires actual successful build; no execution."""
import argparse
import ast
import hashlib
import json
from pathlib import Path

HERE=Path(__file__).resolve().parent
ROOT=HERE.parent/'local-mtp-dense-harness-draft'
BASE=ROOT.parent/'harness-local-mtp-bound-memo'
BASE_SHA='8d0e6cc91591ed959f9774762cf973ec4a28d182072115300d2e372a26cea3fb'
OMIT={'required-native-sources.json','required-native-sources.template.json','freeze.py'}

def raw(path):
    assert path.is_file() and not path.is_symlink() and path.stat().st_size<=2*1024**2,str(path)
    return path.read_bytes()
def sha(data):return hashlib.sha256(data).hexdigest()
def pin(path):return dict(path=str(path),sha256=sha(raw(path)))

def verify():
    assert sha(raw(ROOT/'source-inputs.json'))=='1015bd3810462d99ab30b0549b36f5b1b14eb212308816da14a78d8167938412'
    for own in json.loads(raw(HERE/'source-inputs.json'))['members']:
        data=raw(HERE/own['path']);assert (len(data),sha(data))==(own['bytes'],own['sha256'])
    manifest=json.loads(raw(ROOT/'source-inputs.json'))
    for row in manifest['members']:
        data=raw(ROOT/row['path']);assert (len(data),sha(data))==(row['bytes'],row['sha256']),row['path']
    base_raw=raw(BASE/'source-inputs.json');assert sha(base_raw)==BASE_SHA
    base=json.loads(base_raw);assert len(base['members'])==39
    projected={}
    for row in base['members']:
        name=row['path'];rel=Path(name);assert not rel.is_absolute() and '..' not in rel.parts
        data=raw(BASE/rel);assert (len(data),sha(data))==(row['bytes'],row['sha256'])
        if name not in OMIT:projected[name]=data
    for row in manifest['members']:
        if row['path'].startswith('proposed/'):
            name=row['path'][9:];assert name and name not in OMIT
            projected[name]=raw(ROOT/row['path'])
    for name,data in projected.items():
        if name.endswith('.py'):ast.parse(data,name)
    template=json.loads(raw(ROOT/'required-native-sources.template.json'))
    index={x['path']:x for x in template['requiredFiles']};assert len(index)==len(template['requiredFiles'])==116
    spec=json.loads(raw(ROOT/'binding-spec.json'))
    for row in spec['sourcePackages']:assert sha(raw(Path(row['path'])))==row['sha256']
    source=json.loads(raw(Path(spec['predecessor']['path'])))
    expected={x['path']:x for x in source['files']}
    for row in json.loads(raw(Path(spec['unionIntegration'])))['changes']:
        assert expected[row['target']]==row['before']
        expected[row['target']]=dict(path=row['target'],bytes=row['source']['bytes'],sha256=row['source']['sha256'])
    assert index==expected
    assert sha(raw(Path(template['metadataSources']['path'])))==template['metadataSources']['sha256']
    return projected,template,spec

def bind_resources(actual,expected):
    # Exact closed relative names form a bijection; input list order is irrelevant.
    names={'mlx.metallib','mlx-swift-lm_MLXLMCommon.bundle/pagedattention.metal'}
    assert type(actual) is list and type(expected) is list and len(actual)==len(expected)==2
    expected_by_name={}
    for row in expected:
        assert set(row)=={'path','bytes','sha256'} and row['path'].startswith('bundle/')
        name=row['path'].removeprefix('bundle/')
        assert name in names and name not in expected_by_name
        expected_by_name[name]=row
    assert set(expected_by_name)==names
    actual_by_name={}
    for row in actual:
        assert set(row)=={'path','bytes','sha256'} and type(row['path']) is str
        path=Path(row['path']);assert path.is_absolute() and '..' not in path.parts
        matched=[name for name in names if row['path'].endswith('/'+name)]
        assert len(matched)==1 and matched[0] not in actual_by_name
        actual_by_name[matched[0]]=row
    assert set(actual_by_name)==names
    for name,row in expected_by_name.items():
        value=actual_by_name[name]
        assert type(value['bytes']) is int and value['bytes']==row['bytes']
        assert type(value['sha256']) is str and value['sha256']==row['sha256']

def bind(build_path,sources_path,template,spec):
    assert all(p.is_absolute() and p.parent.resolve()==p.parent for p in (build_path,sources_path))
    assert pin(sources_path)==spec['actualAppliedSource'],'Exact applied union source required'
    build=json.loads(raw(build_path));source=json.loads(raw(sources_path))
    assert build['status']=='passed' and build['exitCode']==0 and build['compilerReaped'] is True and build['groupAbsent'] is True
    assert build['gpuExecuted'] is False and build['sourcesSHA256']==sha(raw(sources_path))
    assert type(build['nativeSHA256']) is str and len(build['nativeSHA256'])==64 and all(x in '0123456789abcdef' for x in build['nativeSHA256'])
    assert type(build['nativeBytes']) is int and 0<build['nativeBytes']<=200_000_000
    assert '--product' in build['argv'] and build['argv'][build['argv'].index('--product')+1]=='GemmaResidentBenchmark'
    actual={x['path']:x for x in source['files']};expected={x['path']:x for x in template['requiredFiles']}
    assert len(actual)==len(source['files'])==116 and actual==expected and source['workspaceMutated'] is True
    bind_resources(build['resources'],template['resources'])
    return dict(template,actualBuildReceipt=pin(build_path),actualSources=pin(sources_path),
        nativeSHA256=build['nativeSHA256'],nativeBytes=build['nativeBytes'])

def main():
    parser=argparse.ArgumentParser(allow_abbrev=False)
    group=parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--check',action='store_true');group.add_argument('--output',type=Path)
    parser.add_argument('--build-receipt',type=Path);parser.add_argument('--sources',type=Path)
    args=parser.parse_args();projected,template,spec=verify()
    if args.check:
        assert args.build_receipt is None and args.sources is None
        print(json.dumps(dict(status='source-checked',baseMembers=39,projectedMembers=len(projected),requiredNativeSources=116,materialized=False)))
        return
    assert args.build_receipt and args.sources
    required=bind(args.build_receipt,args.sources,template,spec)
    target=args.output;assert target==ROOT.parent/'harness-local-mtp-dense-v1' and target.parent.resolve()==target.parent and not target.exists()
    projected['required-native-sources.json']=(json.dumps(required,indent=2)+'\n').encode()
    projected['dense-activation-provenance.json']=(json.dumps(dict(schema='gemma4_local_mtp_dense_preparation_v1',
        predecessorSourceManifestSHA256=BASE_SHA,draftSourceManifestSHA256=sha(raw(ROOT/'source-inputs.json')),
        resourceBindingCorrectionSHA256=sha(raw(HERE/'source-inputs.json')),
        sourcePackages=spec['sourcePackages'],actualBuildReceipt=required['actualBuildReceipt'],actualSources=required['actualSources'],
        nativeIdentityLateVerifiedByOriginalActivation=True,physicalExecuted=False,compilerExecuted=False),indent=2)+'\n').encode()
    target.mkdir(mode=0o700);members=[]
    for name,data in sorted(projected.items()):
        path=target/name;path.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
        with path.open('xb') as stream:stream.write(data)
        members.append(dict(path=name,bytes=len(data),sha256=sha(data)))
    with (target/'source-inputs.json').open('x') as stream:
        json.dump(dict(schema='gemma4_local_mtp_harness_sources_v1',members=members),stream,indent=2);stream.write('\n')
    print(json.dumps(dict(status='source-prepared',output=str(target),sourceSHA256=sha(raw(target/'source-inputs.json')),members=len(members))))

if __name__=='__main__':main()
