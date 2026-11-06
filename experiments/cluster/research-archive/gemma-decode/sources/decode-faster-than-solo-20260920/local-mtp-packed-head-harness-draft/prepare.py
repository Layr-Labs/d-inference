"""Create-only packed-head harness; reuse exact qualified lifecycle/readers."""
import argparse
import ast
import hashlib
import importlib.util
import json
from pathlib import Path
ROOT=Path(__file__).resolve().parent
PARENT=ROOT.parent/'local-mtp-dense-harness-draft'
CORRECTION=ROOT.parent/'local-mtp-dense-resource-binding-correction'
ACTIVATION=ROOT.parent.parent/'gemma4-mtp-packed-head-activation-20260920'
OUTPUT=ROOT.parent/'harness-local-mtp-packed-head-v1'

def raw(path):
    assert path.is_file() and not path.is_symlink() and path.stat().st_size<=2*1024**2,str(path)
    return path.read_bytes()
def sha(data):return hashlib.sha256(data).hexdigest()
def pin(path):return dict(path=str(path),sha256=sha(raw(path)))
def read_pin(row):
    data=raw(Path(row['path']));assert sha(data)==row['sha256']
    if 'bytes' in row:assert len(data)==row['bytes']
    return json.loads(data)
def parent():
    spec=importlib.util.spec_from_file_location('serial_resource_binder',CORRECTION/'prepare.py')
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    return module

def verify():
    for row in json.loads(raw(ROOT/'source-inputs.json'))['members']:
        data=raw(ROOT/row['path']);assert (len(data),sha(data))==(row['bytes'],row['sha256'])
    bindings=json.loads(raw(ROOT/'bindings.json'))
    assert bindings['serialHarness']['sha256']=='1015bd3810462d99ab30b0549b36f5b1b14eb212308816da14a78d8167938412'
    assert bindings['resourceBindingCorrection']['sha256']=='9b4d571aef287b630f6eb42077e0b33e12318a1f46895535977338c2781bee0f'
    assert bindings['activation']['sha256']=='ad9427674dc45b8d56ca96af5d7983cc4cba7f2f6d9f39ee9059f9bc393c2e01'
    for name in ['serialHarness','resourceBindingCorrection','activation','composition','expectedSources','qualification']:read_pin(bindings[name])
    for directory,key in [(PARENT,'serialHarness'),(CORRECTION,'resourceBindingCorrection'),(ACTIVATION,'activation')]:
        for row in read_pin(bindings[key])['members']:
            data=raw(directory/row['path']);assert (len(data),sha(data))==(row['bytes'],row['sha256'])
    projected,_,_=parent().verify()
    changes=json.loads(raw(ROOT/'transformations.json'))['changes']
    assert len({x['path'] for x in changes})==len(changes)
    for row in changes:
        before=projected[row['path']]
        assert dict(bytes=len(before),sha256=sha(before))==row['before']
        value=before.decode()
        for op in row['operations']:
            assert value.count(op['before'])==op['count'];value=value.replace(op['before'],op['after'])
        after=raw(ROOT/'proposed'/row['path'])
        assert value.encode()==after and dict(bytes=len(after),sha256=sha(after))==row['after']
        projected[row['path']]=after
    for name,data in projected.items():
        if name.endswith('.py'):ast.parse(data,name)
    # All numerical/physical helper definitions outside the policy orchestration are exact.
    old=ast.parse(raw(PARENT/'proposed/numerical_compare.py'))
    new=ast.parse(projected['numerical_compare.py'])
    defs=lambda tree:{n.name:ast.dump(n,include_attributes=False) for n in tree.body if isinstance(n,(ast.FunctionDef,ast.ClassDef)) and n.name!='compare'}
    assert defs(old)==defs(new)
    template=json.loads(raw(ROOT/'required-native-sources.template.json'))
    expected=read_pin(bindings['expectedSources'])['files']
    assert len(expected)==len({x['path'] for x in expected})==116 and template['requiredFiles']==expected
    composition=read_pin(bindings['composition'])
    base=read_pin(composition['baseSources']);files={x['path']:x for x in base['files']}
    for row in composition['files']:
        assert files[row['path']]==row['before']
        files[row['path']]=dict(path=row['path'],bytes=row['bytes'],sha256=row['sha256'])
    assert [files[k] for k in sorted(files)]==expected
    qualification=read_pin(bindings['qualification']);build=read_pin(composition['baseBuild'])
    assert qualification['status']=='passed' and qualification['sourceSHA256']==composition['baseSources']['sha256']
    assert qualification['nativeSHA256']==build['nativeSHA256']
    assert qualification['projectionPolicy']=='gemma4_verification_packed_m1_dense_packed_head_v1'
    numeric=qualification['numerical']
    assert numeric['exactNumericsPassed'] is True and numeric['toleranceApplied'] is False
    assert (numeric['fullRowsRead'],numeric['nativeStateComponentsRead'])==(24,360)
    return projected,template,bindings

def bind(build_path,sources_path,template,bindings):
    assert all(p.is_absolute() and p.parent.resolve()==p.parent for p in (build_path,sources_path))
    assert str(sources_path)==bindings['plannedAppliedSources']
    build=json.loads(raw(build_path));source=json.loads(raw(sources_path))
    assert build['status']=='passed' and build['exitCode']==0 and build['compilerReaped'] is True and build['groupAbsent'] is True
    assert build['gpuExecuted'] is False and build['sourcesSHA256']==sha(raw(sources_path))
    assert type(build['nativeSHA256']) is str and len(build['nativeSHA256'])==64 and all(x in '0123456789abcdef' for x in build['nativeSHA256'])
    assert type(build['nativeBytes']) is int and 0<build['nativeBytes']<=200_000_000
    assert '--product' in build['argv'] and build['argv'][build['argv'].index('--product')+1]=='GemmaResidentBenchmark'
    actual={x['path']:x for x in source['files']};expected={x['path']:x for x in template['requiredFiles']}
    assert len(actual)==len(source['files'])==116 and actual==expected and source['workspaceMutated'] is True
    composition=read_pin(bindings['composition'])
    assert source['packedHeadActivationPredecessor']==composition['baseSources']
    assert source['packedHeadActivationManifestSHA256']==bindings['activation']['sha256']
    assert source['packedHeadActivationCompositionSHA256']==bindings['composition']['sha256']
    assert source['packedHeadQualification']==bindings['qualification']
    parent().bind_resources(build['resources'],template['resources'])
    return dict(template,actualBuildReceipt=pin(build_path),actualSources=pin(sources_path),
        nativeSHA256=build['nativeSHA256'],nativeBytes=build['nativeBytes'])

def main():
    parser=argparse.ArgumentParser(allow_abbrev=False)
    group=parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--check',action='store_true');group.add_argument('--output',type=Path)
    parser.add_argument('--build-receipt',type=Path);parser.add_argument('--sources',type=Path)
    args=parser.parse_args();projected,template,bindings=verify()
    if args.check:
        assert args.build_receipt is None and args.sources is None
        print(json.dumps(dict(status='source-checked',projectedMembers=len(projected),requiredNativeSources=116,materialized=False)))
        return
    assert args.build_receipt and args.sources
    required=bind(args.build_receipt,args.sources,template,bindings)
    target=args.output;assert target==OUTPUT and target.parent.resolve()==target.parent and not target.exists()
    projected['required-native-sources.json']=(json.dumps(required,indent=2)+'\n').encode()
    projected['dense-activation-provenance.json']=(json.dumps(dict(schema='gemma4_local_mtp_packed_head_preparation_v1',
        draftSourceManifestSHA256=sha(raw(ROOT/'source-inputs.json')),bindings=bindings,
        actualBuildReceipt=required['actualBuildReceipt'],actualSources=required['actualSources'],
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
