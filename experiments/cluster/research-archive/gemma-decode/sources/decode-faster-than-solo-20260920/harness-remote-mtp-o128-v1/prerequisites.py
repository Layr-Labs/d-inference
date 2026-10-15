"""Bind completed diagnostics before real remote model execution is prepared."""
import hashlib,json
from pathlib import Path
ROOT=Path(__file__).resolve().parent
POLICY='gemma4_verification_packed_m1_dense_packed_head_v1'
GROUPS=['seven-roots-queued-fenced-pull-finish','queued-work-cancelled-after-fence',
        'post-receive-check-failure-retains-roots','stale-sequence-refused','nonzero-padding-refused']

def read(path):
    path=Path(path);assert path.is_absolute() and path.parent.resolve()==path.parent and path.is_file() and not path.is_symlink()
    assert path.stat().st_size<=1048576
    raw=path.read_bytes()
    return json.loads(raw),dict(path=str(path),bytes=len(raw),sha256=hashlib.sha256(raw).hexdigest())

def bind(tiny_path):
    expected=json.loads((ROOT/'qualification-inputs.json').read_bytes())
    dense,pin=read(expected['dense']['path']);assert pin==expected['dense']
    assert dense['schema']=='gemma4_target_width_physical_numerical_comparison_v1' and dense['status']=='passed'
    assert dense['nativeOperation']=='qualify-mtp-target-width-dense-head' and dense['projectionPolicy']==POLICY
    assert dense['nativeSHA256']==expected['denseNativeSHA256'] and dense['sourceSHA256']==expected['denseBaseSources']['sha256']
    assert dense['physicalExecutionPassed'] is True and dense['originalProcessRetired'] is True and dense['sameEmptyLeaseInode'] is True
    numerical=dense['numerical']
    assert numerical['exactNumericsPassed'] is True and numerical['fullRowsRead']==24 and numerical['nativeStateComponentsRead']==360
    assert numerical['toleranceApplied'] is False and dense['performanceQualified'] is False and dense['remoteExecutionQualified'] is False
    tiny,tiny_pin=read(tiny_path)
    assert tiny_pin==expected['tiny']
    assert tiny['schema']=='gemma4_remote_mtp_pull_physical_qualification_v1' and tiny['status']=='passed'
    assert tiny['nativeSHA256']==expected['nativeSHA256'] and tiny['sourcesSHA256']==expected['baseSources']['sha256']
    assert tiny['originalProcessesRetired'] is True and tiny['sameEmptyLeaseInodes'] is True and tiny['aliasRestored'] is True
    assert tiny['groups']==GROUPS and tiny['groupCount']==5 and tiny['actualSnapshotAndScalarProtocolQualified'] is True
    for key in ['gemmaWeightsExecuted','assistantWeightsExecuted','actualGPUFaultInjected','throughputMeasured','encryptedRDMAEstablished']:
        assert tiny[key] is False
    return dict(dense=pin,tiny=tiny_pin)

def recheck(value):
    for pin in value.values():assert read(pin['path'])[1]==pin
