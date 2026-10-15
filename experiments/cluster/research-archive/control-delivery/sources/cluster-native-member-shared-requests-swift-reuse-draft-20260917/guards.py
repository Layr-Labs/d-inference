"""Source/receipt guards for one explicit incremental workspace successor."""
import hashlib
import json
from pathlib import Path
import source_inventory as inventory
from context import BASE,ADAPTER,ADAPTER_SHA,PRIOR,ORIGINAL,WORKSPACE,OUTPUT,SOURCE,original

def sha(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()
def save(path,value):
    with Path(path).open('x') as stream:json.dump(value,stream,indent=2,sort_keys=True);stream.write('\n')
def require(value,message):
    if not value:raise ValueError(message)
def freeze(root,expected=None):
    if expected is not None:require(sha(root/'manifest.json')==expected,'Frozen manifest changed')
    for row in json.loads((root/'manifest.json').read_text())['files']:
        p=root/row['path'];require(p.is_file() and not p.is_symlink() and sha(p)==row['sha256'],'Frozen member changed: '+str(p))
def verify():
    freeze(BASE);freeze(ADAPTER,ADAPTER_SHA)
    effective=original.verify()['files']
    history=json.loads((BASE/'qualified-inputs.json').read_text())
    for row in history['files']:
        p=Path(row['path']);require(p.is_file() and not p.is_symlink() and p.stat().st_size==row['bytes'] and sha(p)==row['sha256'],'Qualified evidence changed')
    for name in ['tests-2','build-2']:
        value=json.loads((PRIOR/name/'checks.json').read_text());step=json.loads((PRIOR/name/'execution.json').read_text())
        require(value['passed'] and step['exitCode']==0 and step['reaped'] and step['groupAbsent'] and not step['timedOut'] and not step['killedOwnedGroup'],'Prior child did not naturally complete')
        require(value['executionSHA256']==sha(PRIOR/name/'execution.json') and value['candidate2SHA256']==sha(PRIOR/'candidate-2-before.json'),'Prior qualification binding')
    prior=json.loads((PRIOR/'tests-2/checks.json').read_text())
    require(prior['details']['testsPassed']==88 and prior['details']['suitesPassed']==14 and prior['details']['invocationMethodsPassed']==10,'Prior tests incomplete')
    binary=json.loads((PRIOR/'build-2/checks.json').read_text())['details']
    require(binary['binarySHA256']==history['priorCLI_SHA256'] and binary['binaryBytes']==history['priorCLIBytes'],'Prior CLI differs')
    helper=json.loads((ORIGINAL/'helper-1/checks.json').read_text())
    require(helper['passed'] and helper['phase']=='helper','Prior helper incomplete')
    for row in helper['artifacts']:
        p=Path(row['path']);require(p.parent==ORIGINAL/'helper-1' and sha(p)==row['sha256'],'Preserved helper changed')
    before=json.loads((ORIGINAL/'source-before.json').read_text());old=json.loads((PRIOR/'candidate-2-before.json').read_text());candidate=dict(before)
    for row in effective:candidate[row['path']]={'sha256':row['proposedSHA256']}
    plan=json.loads((BASE/'integration.json').read_text())
    require(plan['oldCandidateSHA256']==sha(PRIOR/'candidate-2-before.json') and plan['effectiveSourceSHA256']==sha(ADAPTER/'integration.json'),'Composition identity differs')
    rows=plan['files'];changed={p for p in set(old)|set(candidate) if old.get(p)!=candidate.get(p)}
    require(changed=={x['path'] for x in rows} and len(rows)==37 and len(candidate)==13853 and len(old)==13839,'Exact incremental delta differs')
    for row in rows:
        require(old.get(row['path'],{}).get('sha256')==row['beforeSHA256'] and candidate[row['path']]=={'sha256':row['afterSHA256']} and sha(row['sourcePath'])==row['afterSHA256'],'Delta source/preimage differs')
    coverage=json.loads((BASE/'coverage.json').read_text())
    require(set(sum(coverage['groups'].values(),[]))==set(original.INVOCATION_METHODS),'Required method membership differs')
    return rows,before,old,candidate

def recheck_sources(candidate,before):
    actual=inventory.inventory(WORKSPACE);main=inventory.inventory(SOURCE)
    require(actual==candidate and main==before,'Private or MAIN source/dependencies differ')
    prep=json.loads((ORIGINAL/'preparation.json').read_text())
    require(sha(ORIGINAL/'workspace-state-relocated.json')==prep['privateWorkspaceStateSHA256'],'Qualified dependency resolution pin differs')
    require(json.loads((WORKSPACE/'provider-swift/.build/workspace-state.json').read_text())==json.loads((ORIGINAL/'workspace-state-relocated.json').read_text()),'Dependency resolution changed')
    return actual,main

def require_preserved_cli():
    history=json.loads((BASE/'qualified-inputs.json').read_text());p=OUTPUT/'qualified-cli/darkbloom'
    require(p.is_file() and not p.is_symlink() and p.stat().st_size==history['priorCLIBytes'] and sha(p)==history['priorCLI_SHA256'],'Preserved qualified CLI changed')
