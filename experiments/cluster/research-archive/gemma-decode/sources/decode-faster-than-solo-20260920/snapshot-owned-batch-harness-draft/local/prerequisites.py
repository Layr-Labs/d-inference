"""Original packed arithmetic evidence plus a NEW same-build owned-batch tiny run."""
import hashlib,json
from pathlib import Path
ROOT=Path(__file__).resolve().parent
POLICY='gemma4_verification_packed_m1_dense_packed_head_v1'
SNAPSHOT='gemma4_owned_snapshot_batch_gpu_boundaries_v1'
GROUPS=['seven-roots-queued-fenced-pull-finish','queued-work-cancelled-after-fence',
        'post-receive-check-failure-retains-roots','stale-sequence-refused','nonzero-padding-refused']
def read(path):
    path=Path(path);assert path.is_absolute() and path.parent.resolve()==path.parent and path.is_file() and not path.is_symlink()
    assert 0<path.stat().st_size<=4*1024**2
    raw=path.read_bytes();return json.loads(raw),dict(path=str(path),bytes=len(raw),sha256=hashlib.sha256(raw).hexdigest())
def validate_tiny(tiny,native_sha,sources_sha,harness_sha):
    assert tiny['schema']=='gemma4_remote_mtp_owned_batch_physical_qualification_v1' and tiny['status']=='passed'
    assert tiny['nativeSHA256']==native_sha and tiny['sourcesSHA256']==sources_sha and tiny['harnessSourceSHA256']==harness_sha
    assert tiny['snapshotTransferPolicy']==SNAPSHOT
    assert tiny['originalProcessesRetired'] is True and tiny['sameEmptyLeaseInodes'] is True and tiny['aliasRestored'] is True
    assert tiny['groups']==GROUPS and tiny['groupCount']==5 and tiny['actualSnapshotAndScalarProtocolQualified'] is True
    assert tiny['hiddenDTypesQualified']==['bfloat16','float16','float32'] and tiny['noncontiguousFullHeadProducers'] is True
    assert tiny['injectedPreassemblyCheckFailure'] is True and type(tiny['perSnapshotTransferCount']) is int and tiny['perSnapshotTransferCount']==7
    assert type(tiny['perSnapshotCheckedBoundaryCount']) is int and tiny['perSnapshotCheckedBoundaryCount']==2
    for key in ['gemmaWeightsExecuted','assistantWeightsExecuted','actualGPUFaultInjected','throughputMeasured','encryptedRDMAEstablished']:
        assert tiny[key] is False

def bind(tiny_path,native_sha,sources_sha):
    expected=json.loads((ROOT/'qualification-inputs.json').read_bytes())
    dense,dpin=read(expected['dense']['path']);assert dpin==expected['dense']
    assert dense['schema']=='gemma4_target_width_physical_numerical_comparison_v1' and dense['status']=='passed'
    assert dense['nativeOperation']=='qualify-mtp-target-width-dense-head' and dense['projectionPolicy']==POLICY
    assert dense['nativeSHA256']==expected['denseNativeSHA256'] and dense['sourceSHA256']==expected['denseBaseSources']['sha256']
    assert dense['physicalExecutionPassed'] is True and dense['originalProcessRetired'] is True and dense['sameEmptyLeaseInode'] is True
    numerical=dense['numerical']
    assert numerical['exactNumericsPassed'] is True and numerical['fullRowsRead']==24 and numerical['nativeStateComponentsRead']==360
    assert numerical['toleranceApplied'] is False and dense['performanceQualified'] is False and dense['remoteExecutionQualified'] is False
    harness,hpin=read(expected['tinyHarness']['path']);assert hpin==expected['tinyHarness']
    root=Path(hpin['path']).parent;tiny_path=Path(tiny_path)
    assert tiny_path.parent.parent==root/'cases' and tiny_path.name=='physical-result.json'
    for row in harness['members']:
        p=root/row['path'];assert p.is_file() and not p.is_symlink() and p.stat().st_size==row['bytes']
        assert hashlib.sha256(p.read_bytes()).hexdigest()==row['sha256']
    tiny,tpin=read(tiny_path);validate_tiny(tiny,native_sha,sources_sha,hpin['sha256'])
    assert hpin in tiny['retainedInputPins']
    action,apin=read(root/'root-actions'/('compare-'+tiny_path.parent.name)/'receipt.json')
    assert action['status']=='passed' and action['action']=='compare' and action['sourceManifestSHA256']==hpin['sha256']
    assert action['exitCode']==0 and action['reaped'] is True and action['groupAbsent'] is True and action['killedOwnedGroup'] is False
    assert action['argv']==['/usr/bin/python3','-B',str(root/'compare.py'),'--case',tiny_path.parent.name,'--output',str(tiny_path)]
    return dict(dense=dpin,tiny=tpin,tinyHarness=hpin,tinyComparisonAction=apin)
def recheck(value):
    for row in value.values():assert read(row['path'])[1]==row
