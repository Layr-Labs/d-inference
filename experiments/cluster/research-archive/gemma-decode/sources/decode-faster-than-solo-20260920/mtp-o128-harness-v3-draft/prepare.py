"""Create-only O16/O128 sources bound to one reviewed actual native build."""
import importlib.util
import argparse
import ast
import hashlib
import json
from pathlib import Path

ROOT=Path(__file__).resolve().parent
B=ROOT.parent
OUTPUTS={k:B/name for k,name in dict(local='harness-local-mtp-o128-v3',
    remote='harness-remote-mtp-o128-v3',numerical='remote-mtp-o128-numerical-v3').items()}

def read(path):
    path=Path(path)
    assert path.is_absolute() and path.parent.resolve()==path.parent
    assert path.is_file() and not path.is_symlink() and path.stat().st_size<=2*1024**2,path
    return path.read_bytes()

def sha(raw):return hashlib.sha256(raw).hexdigest()
def encode(value):return (json.dumps(value,indent=2,allow_nan=False)+'\n').encode()
def pin(path):
    raw=read(path);return dict(path=str(path),bytes=len(raw),sha256=sha(raw))
def pinned(row):
    raw=read(row['path']);assert len(raw)==row['bytes'] and sha(raw)==row['sha256'],row['path']
    return raw

def members(directory,manifest):
    result={}
    for row in manifest['members']:
        name=row['path'];assert name not in result and not Path(name).is_absolute() and '..' not in Path(name).parts
        raw=read(directory/name);assert (len(raw),sha(raw))==(row['bytes'],row['sha256'])
        result[name]=raw
    return result

def module(name,path):
    spec=importlib.util.spec_from_file_location(name,path);value=importlib.util.module_from_spec(spec);spec.loader.exec_module(value);return value

def verify():
    members(ROOT,json.loads(read(ROOT/'source-inputs.json')))
    spec=json.loads(read(ROOT/'bindings.json'))
    for row in spec['authorities']:pinned(row)
    parent=module('o128_predecessor',Path(spec['parent']['path']).parent/'prepare.py')
    old,projects,measurement_union,_=parent.verify()
    composer=module('description_correction',Path(spec['native']['manifest']['path']).parent/'compose.py')
    union,_,expected=composer.check()
    assert len(expected)==122 and union['baseSources']['path']==old['plannedSources']
    for kind in ('local','remote'):
        before='gemma4-'+('local' if kind=='local' else 'remote')+'-mtp-o128-20260920-v2'
        after=before.removesuffix('v2')+'v3'
        for name,raw in list(projects[kind].items()):
            if name.endswith('.py'):projects[kind][name]=raw.replace(before.encode(),after.encode())
    for row in spec['overlays']:
        before=projects[row['kind']].get(row['path'])
        assert (None if before is None else dict(bytes=len(before),sha256=sha(before)))==row['before']
        after=read(ROOT/row['source']);assert dict(bytes=len(after),sha256=sha(after))==row['after']
        projects[row['kind']][row['path']]=after
    for files in projects.values():
        for name,raw in files.items():
            if name.endswith('.py'):ast.parse(raw,name)
    assert projects['local']['numerical_compare.py']==projects['numerical']['numeric_reader.py']
    for kind in ('local','remote'):
        for name,raw in projects[kind].items():
            if name.endswith('.py'):assert b'mtp-o128-20260920-v1' not in raw and b'mtp-o128-20260920-v2' not in raw
    assert b'validate_description_targets(result,job)' in projects['local']['remote_metadata.py']
    spec.update(bases=old['bases'],producerSources=old['producerSources'],control=old['control'],controlUnion=old['controlUnion'],
        measurement=old['native'],measurementUnion=measurement_union)
    return spec,projects,union,expected

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

def bind(build_path,source_path,spec,union,expected):
    assert str(source_path)==spec['plannedSources'] and str(build_path)==spec['plannedBuild']
    source=json.loads(read(source_path));build=json.loads(read(build_path))
    assert source['files']==expected and source['workspaceMutated'] is True
    assert source['outputDescriptionPredecessor']==union['baseSources']
    assert source['outputDescriptionCorrectionManifestSHA256']==spec['native']['manifest']['sha256']
    assert source['outputDescriptionCorrectionIntegrationSHA256']==spec['native']['integration']['sha256']
    assert source['remoteMeasurementBaseSources']==spec['measurementUnion']['baseSources']
    assert source['remoteMeasurementCompositionManifestSHA256']==spec['measurement']['manifest']['sha256']
    assert source['remoteMeasurementIntegrationSHA256']==spec['measurement']['integration']['sha256']
    for name,want in spec['measurementUnion']['sourceFields'].items():assert source[name]==want
    assert source['remoteControlBaseSources']==spec['controlUnion']['baseSources']
    assert source['remoteControlSourceManifestSHA256']==spec['control']['manifest']['sha256']
    assert source['remoteControlIntegrationSHA256']==spec['control']['integration']['sha256']
    for name,want in spec['controlUnion']['sourceFields'].items():assert source[name]==want
    assert build['status']=='passed' and build['exitCode']==0 and build['compilerReaped'] is True
    assert build['groupAbsent'] is True and build['gpuExecuted'] is False
    assert build['sourcesSHA256']==sha(read(source_path))
    assert build['argv'][build['argv'].index('--product')+1]=='GemmaResidentBenchmark'
    assert type(build['nativeSHA256']) is str and len(build['nativeSHA256'])==64
    assert all(c in '0123456789abcdef' for c in build['nativeSHA256'])
    assert type(build['nativeBytes']) is int and 0<build['nativeBytes']<=200000000
    return build,source

def source_manifest(files):
    return dict(schema='gemma4_o128_harness_sources_v1',members=[dict(path=k,bytes=len(v),sha256=sha(v)) for k,v in sorted(files.items())])

def prepare(build_path,source_path):
    spec,projects,union,expected=verify();build,source=bind(build_path,source_path,spec,union,expected)
    assert all(not p.exists() and not p.is_symlink() and p.parent.resolve()==p.parent for p in OUTPUTS.values())
    for kind in ('local','remote'):
        old=json.loads(projects[kind]['required-native-sources.json'])
        bind_resources(build['resources'],old['resources'])
        if kind=='remote':old['packedHeadFiles']=old['requiredFiles']
        old.update(requiredFiles=expected,actualBuildReceipt=pin(build_path),actualSources=pin(source_path),
            nativeSHA256=build['nativeSHA256'],nativeBytes=build['nativeBytes'],
            remoteControlSourceManifestSHA256=spec['control']['manifest']['sha256'],
            remoteControlIntegrationSHA256=spec['control']['integration']['sha256'],remoteControlBaseSources=spec['controlUnion']['baseSources'],
            remoteMeasurementBaseSources=spec['measurementUnion']['baseSources'],remoteMeasurementCompositionManifestSHA256=spec['measurement']['manifest']['sha256'],
            remoteMeasurementIntegrationSHA256=spec['measurement']['integration']['sha256'],
            outputDescriptionPredecessor=union['baseSources'],outputDescriptionCorrectionManifestSHA256=spec['native']['manifest']['sha256'],
            outputDescriptionCorrectionIntegrationSHA256=spec['native']['integration']['sha256'],
            **spec['controlUnion']['sourceFields'],**spec['measurementUnion']['sourceFields'])
        projects[kind]['required-native-sources.json']=encode(old)
    provenance=dict(schema='gemma4_o128_source_preparation_v1',draft=pin(ROOT/'source-inputs.json'),
        bases=spec['bases'],native=spec['native'],actualBuildReceipt=pin(build_path),actualSources=pin(source_path),
        outputCounts=[16,128],nativeExecuted=False,compilerExecuted=False,remoteExecuted=False)
    for files in projects.values():files['o128-provenance.json']=encode(provenance)
    manifests={k:source_manifest(projects[k]) for k in ('local','remote')}
    numeric=json.loads(projects['numerical']['inputs.json'])
    for kind in ('local','remote'):
        raw=encode(manifests[kind]);numeric[kind+'Harness']=dict(path=str(OUTPUTS[kind]/'source-inputs.json'),bytes=len(raw),sha256=sha(raw))
    numeric['readers']=[dict(path=name,source=str(ROOT/'proposed/numerical'/name) if (ROOT/'proposed/numerical'/name).exists()
        else str(ROOT.parent/'mtp-o128-harness-v2-draft/proposed/numerical'/name) if (ROOT.parent/'mtp-o128-harness-v2-draft/proposed/numerical'/name).exists()
        else str(ROOT.parent/'mtp-o128-harness-draft/proposed/numerical'/name) if (ROOT.parent/'mtp-o128-harness-draft/proposed/numerical'/name).exists() else str(Path(spec['bases']['numerical']['path']).parent/name),bytes=len(projects['numerical'][name]),sha256=sha(projects['numerical'][name]))
        for name in ('numeric_reader.py','recorded_math.py','snapshot.py','workload_contract.py','control_contract.py','binding_common.py','timing_contract.py')]
    numeric['producerSources']=spec['producerSources']
    projects['numerical']['inputs.json']=encode(numeric);manifests['numerical']=source_manifest(projects['numerical'])
    for kind,target in OUTPUTS.items():
        target.mkdir(mode=0o700)
        for name,raw in sorted(projects[kind].items()):
            path=target/name;path.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
            with path.open('xb') as stream:stream.write(raw)
        with (target/'source-inputs.json').open('xb') as stream:stream.write(encode(manifests[kind]))
    print(json.dumps(dict(status='source-prepared',outputs={k:pin(p/'source-inputs.json') for k,p in OUTPUTS.items()},nativeSHA256=build['nativeSHA256'])))

def main():
    p=argparse.ArgumentParser(allow_abbrev=False);g=p.add_mutually_exclusive_group(required=True)
    g.add_argument('--check',action='store_true');g.add_argument('--prepare',action='store_true')
    p.add_argument('--build-receipt',type=Path);p.add_argument('--sources',type=Path)
    a=p.parse_args()
    if a.check:
        assert a.build_receipt is None and a.sources is None
        _,projects,_,_=verify();print(json.dumps(dict(status='source-checked',projects={k:len(v) for k,v in projects.items()},nativeSources=122,testsExecuted=False)))
    else:
        assert a.build_receipt and a.sources
        prepare(a.build_receipt,a.sources)
if __name__=='__main__':main()
