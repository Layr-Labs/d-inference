"""Exact prior composition, one replacement, original MAIN and reused helper bindings."""
import json
from pathlib import Path
import source_inventory as inventory
from context import BASE,PRIOR,OUTPUT,HELPER,WORKSPACE,SOURCE,INVOCATION_METHODS
from upstream_guards import verify as verify_upstream,recheck_sources,require_preserved_cli,freeze,sha,save,require

def verify():
    freeze(BASE)
    _,before,_,prior=verify_upstream()
    for row in json.loads((BASE/'evidence-pins.json').read_text()):
        p=Path(row['path'])
        require(p.is_file() and not p.is_symlink() and p.stat().st_size==row['bytes'] and sha(p)==row['sha256'],'Prior failure/helper/source evidence changed')
    require(prior==json.loads((PRIOR/'candidate-before.json').read_text()) and len(prior)==13853,'Prior 13853-source composition differs')
    require(before==json.loads((PRIOR/'source-before.json').read_text()) and before==json.loads((PRIOR/'source-after-preparation.json').read_text()),'Original MAIN authority differs')
    step=json.loads((PRIOR/'tests-1/execution.json').read_text())
    require(step['exitCode']==1 and step['reaped'] and step['groupAbsent'] and not step['timedOut'] and not step['killedOwnedGroup'],'Preserved compile failure was not naturally terminal')
    require(json.loads((PRIOR/'tests-1/source-recheck.json').read_text())=={'unchanged':True,'priorQualifiedCLIPreserved':True},'Failed attempt changed source')
    plan=json.loads((BASE/'integration.json').read_text());rows=plan['files']
    require(len(rows)==1 and rows[0]['path']=='provider-swift/Sources/darkbloom/StartCommand+ClusterMember.swift','Only exact CLI file may change')
    row=rows[0];candidate=dict(prior)
    require(prior[row['path']]=={'sha256':row['beforeSHA256']} and sha(BASE/'original'/row['path'])==row['beforeSHA256'] and sha(row['sourcePath'])==row['afterSHA256'],'CLI source/preimage differs')
    candidate[row['path']]={'sha256':row['afterSHA256']}
    require(len(candidate)==13853 and len(INVOCATION_METHODS)==29,'Source or test scope changed')
    return rows,before,prior,candidate

def require_helper():
    p=HELPER/'checks.json'
    require(sha(p)=='aee43c24436ff502e0637618fca53e90f9cca8e021c7d3ad79fb4073d48885ef','Actual helper receipt changed')
    x=json.loads(p.read_text())
    require(x['passed'] is True and x['phase']=='helper' and x['manifestSHA256']=='432f24932fcab4c16d05978e72bc2d067f9a2d7a02c3780f0af1cb9813ca78f2'
        and x['candidateSHA256']==sha(PRIOR/'candidate-before.json'),'Actual helper composition differs')
    require(len(x['artifacts'])==6 and x['details']=={'helperCompiled':True,'legacySSHChecksExecuted':True,'newNativeHelperExecuted':False},'Incomplete actual helper')
    for row in x['artifacts']:
        p=Path(row['path']);require(p.parent==HELPER and p.is_file() and not p.is_symlink() and p.stat().st_size==row['bytes'] and sha(p)==row['sha256'],'Reused helper changed')
    for step in x['steps']:
        require(step['exitCode']==0 and step['reaped'] and step['groupAbsent'] and not step['timedOut'] and not step['killedOwnedGroup'],'Helper command incomplete')
    return x
