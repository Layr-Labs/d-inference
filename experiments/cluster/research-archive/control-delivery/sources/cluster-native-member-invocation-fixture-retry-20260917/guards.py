"""Exact one-test-file retry; original helper and failed evidence remain pinned."""
import hashlib
import json
from pathlib import Path
import source_inventory as inventory
from context import BASE,UPSTREAM,UPSTREAM_SHA,FAILED,RETRY,HELPER_SHA,SOURCE,original

def sha(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()
def save(path,value):
    with Path(path).open('x') as out:json.dump(value,out,indent=2,sort_keys=True);out.write('\n')
def require(value,message):
    if not value:raise ValueError(message)
def freeze(root,expected=None):
    if expected is not None:require(sha(root/'manifest.json')==expected,'Frozen manifest changed')
    for row in json.loads((root/'manifest.json').read_text())['files']:
        p=root/row['path'];require(p.is_file() and not p.is_symlink() and p.stat().st_size==row['bytes'] and sha(p)==row['sha256'],'Frozen member changed: '+str(p))
def verify():
    freeze(BASE);freeze(UPSTREAM,UPSTREAM_SHA);integration=original.verify()
    rows=json.loads((BASE/'integration.json').read_text())['files'];require(len(rows)==1,'One fixture correction only');row=rows[0]
    require(row['path']=='provider-swift/Tests/ProviderCoreTests/Coordinator/NativePairMember/NativePairMemberControlTests.swift','Exact fixture path')
    require(next(r for r in integration['files'] if r['path']==row['path'])['proposedSHA256']==row['baseSHA256'],'Original candidate fixture preimage')
    require(sha(BASE/'originals/NativePairMemberControlTests.swift')==row['baseSHA256'] and sha(BASE/'proposed/NativePairMemberControlTests.swift')==row['proposedSHA256'],'Correction source changed')
    bound=json.loads((BASE/'failure-inputs.json').read_text());require(bound['failedRoot']==str(FAILED),'Failed root differs')
    for value in bound['files']:
        p=FAILED/value['path'];require(p.is_file() and not p.is_symlink() and p.stat().st_size==value['bytes'] and sha(p)==value['sha256'],'Retained evidence changed: '+str(p))
    failed=json.loads((FAILED/'tests-1/execution.json').read_text())
    require(failed['exitCode']==1 and failed['reaped'] and failed['groupAbsent'] and not failed['timedOut'] and not failed['killedOwnedGroup'],'Original compiler must be naturally terminal')
    helper=json.loads((FAILED/'helper-1/checks.json').read_text())
    require(sha(FAILED/'helper-1/checks.json')==HELPER_SHA and helper['passed'] and helper['phase']=='helper' and helper['manifestSHA256']==UPSTREAM_SHA and helper['candidateSHA256']==sha(FAILED/'candidate-before.json'),'Qualified original helper binding')
    for artifact in helper['artifacts']:
        p=Path(artifact['path']);require(p.parent==FAILED/'helper-1' and p.is_file() and not p.is_symlink() and p.stat().st_size==artifact['bytes'] and sha(p)==artifact['sha256'],'Original compiled helper artifact changed')
    before=json.loads((FAILED/'source-before.json').read_text());candidate=json.loads((FAILED/'candidate-before.json').read_text())
    expected=dict(before)
    for value in integration['files']:expected[value['path']]={'sha256':value['proposedSHA256']}
    require(expected==candidate,'Original candidate source composition')
    require(candidate[row['path']]=={'sha256':row['baseSHA256']},'Original fixture source identity')
    corrected=dict(candidate);corrected[row['path']]={'sha256':row['proposedSHA256']}
    return row,before,candidate,corrected
def recheck(expected,before):
    actual=inventory.inventory(FAILED/'workspace');main=inventory.inventory(SOURCE)
    require(actual==expected and main==before,'Private/MAIN source and dependencies changed')
    prior=json.loads((FAILED/'preparation.json').read_text())
    require(prior['workspace']==str(FAILED/'workspace') and prior['source']==str(SOURCE) and prior['wrapperManifestSHA256']==UPSTREAM_SHA,'Original preparation identity')
    require(sha(FAILED/'workspace-state-relocated.json')==prior['privateWorkspaceStateSHA256'],'Retained resolution pin')
    require(json.loads((FAILED/'workspace/provider-swift/.build/workspace-state.json').read_text())==json.loads((FAILED/'workspace-state-relocated.json').read_text()),'Private dependency resolution changed')
    return actual,main
