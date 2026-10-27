"""Exact immutable batch source + actual bounded CPU/build receipt binding."""
import hashlib,json
from pathlib import Path

def sha(path):
    h=hashlib.sha256()
    with Path(path).open('rb') as f:
        for block in iter(lambda:f.read(1024**2),b''):h.update(block)
    return h.hexdigest()
def read(path):
    p=Path(path);assert p.is_absolute() and p.parent.resolve()==p.parent and p.is_file() and not p.is_symlink()
    assert 0<p.stat().st_size<=4*1024**2
    b=p.read_bytes();return json.loads(b),dict(path=str(p),bytes=len(b),sha256=hashlib.sha256(b).hexdigest())
def pinned(row):
    value,actual=read(row['path']);assert actual==row;return value

def source_contract(required,sources):
    manifest=pinned(required['snapshotManifest'])
    base=pinned(required['snapshotBase']);integration=pinned(required['snapshotIntegration'])
    expected_files=pinned(required['snapshotExpectedSources'])['files']
    assert len(expected_files)==len({r['path'] for r in expected_files})==124
    assert required['requiredFiles']==expected_files and len(base['files'])==122
    assert integration['baseSources']==required['snapshotBase'] and integration['expectedSources']==required['snapshotExpectedSources']
    for row in manifest['members']:
        p=Path(required['snapshotManifest']['path']).parent/row['path']
        assert p.is_file() and not p.is_symlink() and p.stat().st_size==row['bytes'] and sha(p)==row['sha256']
    expected=dict(base);expected['files']=expected_files
    expected.update(ownedSnapshotBatchPredecessor=required['snapshotBase'],
        ownedSnapshotBatchManifestSHA256=required['snapshotManifest']['sha256'],
        ownedSnapshotBatchIntegrationSHA256=required['snapshotIntegration']['sha256'],
        ownedSnapshotBatchPolicy='gemma4_owned_snapshot_batch_gpu_boundaries_v1',
        ownedSnapshotBatchChanges=integration['changes'])
    assert sources==expected,'Actual source receipt must be the exact separate batch candidate'
    return sources

def controls(required):
    manifest=pinned(required['controlsManifest']);inputs=pinned(required['controlsInputs'])
    for row in manifest['members']:
        p=Path(required['controlsManifest']['path']).parent/row['path']
        assert p.is_file() and not p.is_symlink() and p.stat().st_size==row['bytes'] and sha(p)==row['sha256']
    receipt,ref=read(required['controlsReceipt'])
    assert receipt['schema']=='gemma4_owned_snapshot_batch_foundation_qualification_v1' and receipt['status']=='passed'
    assert receipt['sourceManifest']==required['controlsManifest'] and receipt['inputs']==inputs
    assert receipt['passed']==inputs['expectedLabels'] and len(receipt['passed'])==12
    assert receipt['nativeInferenceExecuted'] is False and receipt['gpuExecuted'] is False
    for name,bound in [('compile',60),('run',10)]:
        value=receipt[name]
        assert value['status']=='passed' and value['exitCode']==0 and value['reaped'] is True and value['groupAbsent'] is True
        assert value['timeoutSeconds']==bound and value['killedOwnedGroup'] is False and 0<=value['elapsedSeconds']<bound+5
        for suffix in ('stdout','stderr'):
            row=value[suffix];p=Path(row['path'])
            assert p.is_file() and not p.is_symlink() and p.stat().st_size==row['bytes'] and sha(p)==row['sha256']
        assert value['stderr']['bytes']==0
    return ref
