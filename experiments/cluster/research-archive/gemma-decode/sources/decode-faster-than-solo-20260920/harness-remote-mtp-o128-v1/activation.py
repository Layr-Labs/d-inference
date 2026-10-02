"""Bind only an actual successful root build to the reviewed source union."""
from pathlib import Path
import hashlib
import json
ROOT=Path(__file__).resolve().parent

def sha(path):
    h=hashlib.sha256()
    with Path(path).open('rb') as f:
        for block in iter(lambda:f.read(1024**2),b''):h.update(block)
    return h.hexdigest()

def bind(binary,build_path,sources_path,tiny_qualification):
    for p in [binary,build_path,sources_path]:assert p.is_absolute() and p.is_file() and not p.is_symlink() and p.parent.resolve()==p.parent
    required=json.loads((ROOT/'required-native-sources.json').read_bytes())
    for name in ['activationPredecessor','activationManifest','argumentOrderManifest','activationComposition','argumentOrderComposition','unionManifest','unionIntegration','packedHeadManifest']:
        row=required[name];assert sha(Path(row['path']))==row['sha256']
    for name in ['packedHeadActivationManifest','packedHeadActivationComposition','packedHeadActivationExpectedSources','packedHeadActivationPredecessor']:
        row=required[name];assert sha(Path(row['path']))==row['sha256']
    assert json.loads(Path(required['packedHeadActivationExpectedSources']['path']).read_bytes())['files']==required['packedHeadFiles']
    sources=json.loads(sources_path.read_bytes());assert sources['files']==required['requiredFiles']
    assert sources['workspaceMutated'] is True
    assert str(build_path)==required['actualBuildReceipt']['path'] and sha(build_path)==required['actualBuildReceipt']['sha256']
    assert str(sources_path)==required['actualSources']['path'] and sha(sources_path)==required['actualSources']['sha256']
    assert sources['remoteControlSourceManifestSHA256']==required['remoteControlSourceManifestSHA256']
    assert sources['remoteControlIntegrationSHA256']==required['remoteControlIntegrationSHA256']
    assert sources['remoteControlBaseSources']==required['remoteControlBaseSources']
    for name in ('remoteAssistantFreshGuardManifestSHA256','remoteVerificationDepthManifestSHA256','mtpOutputEnvelopeManifestSHA256'):
        assert sources[name]==required[name]
    assert sources['denseActivationManifestSHA256']==required['activationManifest']['sha256']
    assert sources['denseActivationArgumentOrderManifestSHA256']==required['argumentOrderManifest']['sha256']
    assert sources['denseExecutionPredecessor']==required['activationPredecessor']
    assert sources['denseExecutionCompositionManifestSHA256']==required['unionManifest']['sha256']
    assert sources['denseExecutionIntegrationSHA256']==required['unionIntegration']['sha256']
    assert sources['packedHeadManifestSHA256']==required['packedHeadManifest']['sha256']
    assert sources['packedHeadActivationPredecessor']==required['packedHeadActivationPredecessor']
    assert sources['packedHeadActivationManifestSHA256']==required['packedHeadActivationManifest']['sha256']
    assert sources['packedHeadActivationCompositionSHA256']==required['packedHeadActivationComposition']['sha256']
    assert sources['packedHeadQualification']==required['packedHeadQualification']
    from prerequisites import bind as qualification_bind
    prerequisites=qualification_bind(tiny_qualification)
    build=json.loads(build_path.read_bytes())
    assert build['exitCode']==0 and build['compilerReaped'] is True and build['groupAbsent'] is True and build['gpuExecuted'] is False
    assert build['sourcesSHA256']==sha(sources_path) and binary.name=='GemmaResidentBenchmark'
    assert sha(binary)==build['nativeSHA256'] and binary.stat().st_size==build['nativeBytes']
    for row in required['resources']:
        p=binary.parent/row['path'].removeprefix('bundle/')
        assert p.is_file() and not p.is_symlink() and p.stat().st_size==row['bytes'] and sha(p)==row['sha256']
    result=dict(schema='gemma4_remote_mtp_activation_v1',binary=str(binary),nativeSHA256=build['nativeSHA256'],nativeBytes=build['nativeBytes'],
        buildReceipt=str(build_path),buildReceiptSHA256=sha(build_path),sourceReceipt=str(sources_path),sourcesSHA256=sha(sources_path),
        requiredSourcesSHA256=sha(ROOT/'required-native-sources.json'),qualificationInputs=prerequisites,physicalExecuted=False,gemmaWeightsExecuted=False)
    with (ROOT/'activation.json').open('x') as f:json.dump(result,f,indent=2);f.write('\n')
    return result

def recheck():
    value=json.loads((ROOT/'activation.json').read_bytes())
    from prerequisites import recheck as qualification_recheck
    qualification_recheck(value['qualificationInputs'])
    assert sha(Path(value['buildReceipt']))==value['buildReceiptSHA256'] and sha(Path(value['sourceReceipt']))==value['sourcesSHA256']
    assert sha(ROOT/'required-native-sources.json')==value['requiredSourcesSHA256']
    return value
