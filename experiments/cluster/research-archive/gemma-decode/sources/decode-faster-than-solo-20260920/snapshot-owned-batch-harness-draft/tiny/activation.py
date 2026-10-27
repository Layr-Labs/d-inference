"""Only actual successful build/controls; same-build tiny before any model arm."""
import json
from pathlib import Path
from source_binding import sha,read,pinned,source_contract,controls
ROOT=Path(__file__).resolve().parent

def bind(binary,build_path,sources_path,tiny_qualification=None):
    for p in (binary,build_path,sources_path):
        assert p.is_absolute() and p.is_file() and not p.is_symlink() and p.parent.resolve()==p.parent
    required=json.loads((ROOT/'required-native-sources.json').read_bytes())
    source,_=read(sources_path);source_contract(required,source)
    actual_controls=controls(required)
    build,_=read(build_path)
    assert build['exitCode']==0 and build['compilerReaped'] is True and build['groupAbsent'] is True and build['gpuExecuted'] is False
    assert build['sourcesSHA256']==sha(sources_path) and binary.name=='GemmaResidentBenchmark'
    assert 0<build['nativeBytes']<128*1024**2 and binary.stat().st_size==build['nativeBytes'] and sha(binary)==build['nativeSHA256']
    for row in required['resources']:
        p=binary.parent/row['path'].removeprefix('bundle/')
        assert p.is_file() and not p.is_symlink() and p.stat().st_size==row['bytes'] and sha(p)==row['sha256']
    kind=required['activationKind'];assert kind in ('tiny','remote','local')
    prerequisites={}
    if kind!='tiny':
        assert tiny_qualification is not None
        from prerequisites import bind as prerequisite_bind
        prerequisites=prerequisite_bind(tiny_qualification,build['nativeSHA256'],build['sourcesSHA256'])
    else:assert tiny_qualification is None
    result=dict(schema='gemma4_local_mtp_actual_activation_v1' if kind=='local' else 'gemma4_remote_mtp_activation_v1',
        binary=str(binary),nativeSHA256=build['nativeSHA256'],nativeBytes=build['nativeBytes'],
        buildReceipt=str(build_path),buildReceiptSHA256=sha(build_path),sourceReceipt=str(sources_path),sourcesSHA256=sha(sources_path),
        actualFoundationControls=actual_controls,physicalExecuted=False,gemmaWeightsExecuted=False)
    if kind=='local':
        result.update(requiredSourceSHA256=sha(ROOT/'required-native-sources.json'),stateSourceManifestSHA256=required['stateManifestSHA256'],
            outerCheckSourceManifestSHA256=required['outerCheckManifestSHA256'])
    else:result['requiredSourcesSHA256']=sha(ROOT/'required-native-sources.json')
    if kind!='tiny':result['qualificationInputs']=prerequisites
    with (ROOT/'activation.json').open('x') as f:json.dump(result,f,indent=2);f.write('\n')
    return result

def recheck():
    value=json.loads((ROOT/'activation.json').read_bytes())
    assert sha(Path(value['buildReceipt']))==value['buildReceiptSHA256'] and sha(Path(value['sourceReceipt']))==value['sourcesSHA256']
    expected=value.get('requiredSourcesSHA256',value.get('requiredSourceSHA256'))
    assert sha(ROOT/'required-native-sources.json')==expected
    assert read(value['actualFoundationControls']['path'])[1]==value['actualFoundationControls']
    if 'qualificationInputs' in value:
        from prerequisites import recheck as prerequisite_recheck
        prerequisite_recheck(value['qualificationInputs'])
    return value
