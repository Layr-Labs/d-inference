"""Exact source composition and fixed catalog checks only; no Swift/native run."""
from pathlib import Path
import hashlib,json,subprocess,tempfile
BASE=Path(__file__).resolve().parent
MAIN=Path('/Users/developer/DarkbloomDev/d-inference')
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
    inventory=json.loads((BASE/'integration.json').read_bytes())
    assert sha(Path(inventory['scopeManifest']))==inventory['scopeManifestSHA256']
    scope_root=Path(inventory['scopeManifest']).parent
    for row in json.loads(Path(inventory['scopeManifest']).read_bytes())['members']:
        assert sha(scope_root/row['path'])==row['sha256']
    rows=inventory['files'];assert len(rows)==22 and len({r['path'] for r in rows})==22
    for row in rows:
        rel=Path(row['path']);assert not rel.is_absolute() and '..' not in rel.parts
        assert sha(Path(row['source']))==row['afterSHA256']
        old=MAIN/rel
        if row['beforeSHA256'] is None:assert not old.exists()
        else:assert sha(old)==row['beforeSHA256']
    for row in json.loads((BASE/'controls.json').read_bytes())['files']:
        assert sha(MAIN/row['path'])==row['sha256']
    with tempfile.TemporaryDirectory(prefix='collective-probe-source-') as value:
        root=Path(value)
        for row in rows:
            if row['beforeSHA256'] is None:continue
            path=root/row['path'];path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes((MAIN/row['path']).read_bytes())
        p=subprocess.run(['/usr/bin/git','apply','--unsafe-paths',str(BASE/'runtime.patch')],cwd=root,capture_output=True,timeout=10)
        assert p.returncode==0,p.stderr.decode()
        for row in rows:assert sha(root/row['path'])==row['afterSHA256']
    runtime=BASE/'proposed/libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime'
    assert len(list(runtime.glob('*.swift')))==6
    for path in runtime.glob('*.swift'):
        assert path.read_text().startswith('#if COLLECTIVE_RECORD_ALLOCATION_CHECK\n') and path.read_text().endswith('#endif\n')
    footprint=(runtime/'CollectiveAllocationFootprint.swift').read_text()
    assert 'ri_lifetime_max_phys_footprint' in footprint and 'proc_pid_rusage' in footprint
    execution=(runtime/'CollectiveAllocationExecution.swift').read_text()
    assert 'CollectiveAuthenticatedRecords(io:' in execution and 'test.priming.map' in execution
    assert 'sender.status.codec.sealedRecords > sentBefore' in execution
    assert 'receiver.status.codec.openedRecords > openedBefore' in execution
    assert 'published == publishedBefore' in execution
    cases=json.loads((BASE/'PROBE-SCHEDULE.json').read_bytes())['cases']
    assert len(cases)==35 and len({c['id'] for c in cases})==35
    assert sum(c['id'].startswith('fresh-') for c in cases)==17
    assert sum(c['id'].startswith('reused-failure-') for c in cases)==8
    for c in cases:
        assert len(c['priming'])+len(c['geometries'])*c['rounds']<=40
        for shape in c['priming']+c['geometries']:
            element={'uint8':1,'uint32':4,'int32':4,'bfloat16':2,'float32':4}[shape['dtype']]
            count=element
            for dimension in shape['shape']:count*=dimension
            assert count==shape['bytes'] and count<=10485760 and count+40<=16777216
    assert sha(scope_root/'proposed/libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime/CollectiveProtectedResources.swift')==next(r['afterSHA256'] for r in rows if r['path'].endswith('/CollectiveProtectedResources.swift'))
    print(json.dumps(dict(composedFiles=22,newProbeFiles=8,frozenScopeMembers=31,fixedCases=35,shapeFamilies=17,
        patchReplay=True,productionPolicyUnchanged=True,swiftCompiled=False,nativeExecuted=False,profileQualified=False),sort_keys=True))
if __name__=='__main__':main()
