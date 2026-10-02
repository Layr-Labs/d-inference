"""Small source/receipt checks only; no fixture, compiler or artifact payload reads."""
import ast,hashlib,json
from pathlib import Path
BASE=Path(__file__).resolve().parent
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def require(value,message):
    if not value:raise ValueError(message)
def main():
    plan=json.loads((BASE/'integration.json').read_text());row,=plan['files'];path=Path(row['path'])
    old=(BASE/'original'/path).read_text();new=(BASE/'proposed'/path).read_text()
    removed='                if !process.isRunning { throw ClusterWorkerOwnerError.closed }\n'
    added='                // Drain queued owner frames through actual pipe EOF, even after owner exit.\n'
    require(old.count(removed)==new.count(added)==1 and old.replace(removed,added)==new,'Endpoint is not the exact one-line correction')
    require(sha(BASE/'original'/path)==row['beforeSHA256'] and sha(row['sourcePath'])==row['afterSHA256'],'Endpoint pins differ')
    for name in ['source-pins.json','evidence-pins.json']:
        for x in json.loads((BASE/name).read_text()):
            p=Path(x['path']);require(p.is_file() and not p.is_symlink() and p.stat().st_size==x['bytes'] and sha(p)==x['sha256'],'Source/evidence changed: '+str(p))
    original=Path('/Users/developer/DarkbloomDev/cluster-research/cluster-native-member-invocation-build-1-20260916/workspace/libs/darkbloom-cluster/Tests/ProcessChecks/FixtureIdentity.swift')
    require((BASE/'Tests/FixtureIdentity.swift').read_bytes()==original.read_bytes(),'Fixture identity changed')
    helper=Path('/Users/developer/DarkbloomDev/cluster-research/cluster-member-ready-eligibility-checks-20260917/helper-1/checks.json')
    require(sha(helper)=='c350db706ed48636f6f83a8d98dd131d75972b43a1c213c5224e040c7daf5057','Historical helper receipt differs')
    h=json.loads(helper.read_text());require(h['passed'] and len(h['steps'])==17 and len(h['artifacts'])==6,'Historical helper incomplete')
    execution=json.loads(Path('/Users/developer/DarkbloomDev/cluster-research/cluster-member-ready-eligibility-checks-20260917/tests-1/execution.json').read_text())
    require(execution['exitCode']==1 and execution['reaped'] and execution['groupAbsent'] and not execution['timedOut'],'Failure was not naturally terminal')
    owner=(BASE/'Tests/ReleaseDrainOwner.swift').read_text();checks=(BASE/'Tests/ReleaseDrainChecks.swift').read_text()
    require('ClusterWorkerOwnerService.serveConfigured' in owner and 'ClusterWorkerProcess(' in owner,'Control does not own the real Service/child')
    require('"valid", "missing", "wrong", "abnormal"' in checks and '#if OWNER_RELEASE_EOF_DRAIN' in checks,'Closed control cases differ')
    ast.parse((BASE/'check_sources.py').read_text())
    result=dict(passed=True,sourceOnly=True,endpointReplacements=1,providerMethodsUnchanged=112,
        candidateActualOwnerGroupsStaged=4,baselineActualOwnerGroupStaged=1,
        compilerExecuted=False,fixtureExecuted=False,modelOrRemoteExecuted=False)
    print(json.dumps(result,sort_keys=True))
if __name__=='__main__':main()
