"""Preserve actor/failed-run/helper evidence; derive exactly one new runtime preimage."""
import json
from pathlib import Path
from context import BASE,ACTOR,ACTOR_SHA,PRIOR,OUTPUT,OLD_HELPER,WORKSPACE,SOURCE,INVOCATION_METHODS
from upstream_guards import verify as verify_upstream,recheck_sources,require_preserved_cli,freeze,sha,save,require

def verify():
    freeze(BASE);freeze(ACTOR,ACTOR_SHA)
    _,main,_,shared=verify_upstream()
    for row in json.loads((BASE/'evidence-pins.json').read_text()):
        p=Path(row['path'])
        require(p.is_file() and not p.is_symlink() and p.stat().st_size==row['bytes'] and sha(p)==row['sha256'],'Preserved actor/failure/helper evidence changed')
    actor=json.loads((ACTOR/'integration.json').read_text())['files'];prior=dict(shared)
    require(len(actor)==1 and actor[0]['path']=='provider-swift/Sources/darkbloom/StartCommand+ClusterMember.swift','Actor source scope differs')
    for row in actor:
        require(shared[row['path']]=={'sha256':row['beforeSHA256']} and sha(row['sourcePath'])==row['afterSHA256'],'Actor source ancestry differs')
        prior[row['path']]={'sha256':row['afterSHA256']}
    require(prior==json.loads((PRIOR/'candidate-before.json').read_text()) and len(prior)==13853,'Actual actor candidate differs')
    require(main==json.loads((PRIOR/'source-before.json').read_text())==json.loads((PRIOR/'source-after-preparation.json').read_text()),'Original MAIN authority differs')
    step=json.loads((PRIOR/'tests-1/execution.json').read_text())
    require(step['exitCode']==1 and step['reaped'] and step['groupAbsent'] and not step['timedOut'] and not step['killedOwnedGroup'],'Actual 112-test failure was not naturally terminal')
    require(json.loads((PRIOR/'tests-1/source-recheck.json').read_text())==dict(unchanged=True,priorQualifiedCLIPreserved=True,reusedHelperUnchanged=True),'Failed source changed')
    plan=json.loads((BASE/'integration.json').read_text());rows=plan['files'];candidate=dict(prior)
    require(plan['actorManifestSHA256']==ACTOR_SHA and plan['actorCandidateSHA256']==sha(PRIOR/'candidate-before.json'),'Correction ancestry differs')
    require(len(rows)==1 and rows[0]['path']=='libs/darkbloom-cluster/Sources/DarkbloomClusterRemote/ClusterWorkerOwnerService.swift','Only Service eligibility ordering may change')
    row=rows[0]
    require(prior[row['path']]=={'sha256':row['beforeSHA256']} and sha(BASE/'original'/row['path'])==row['beforeSHA256'] and sha(row['sourcePath'])==row['afterSHA256'],'Service source/preimage differs')
    candidate[row['path']]={'sha256':row['afterSHA256']}
    require(len(candidate)==13853 and len(INVOCATION_METHODS)==29,'Candidate or named test scope differs')
    require(sha(OLD_HELPER/'checks.json')=='aee43c24436ff502e0637618fca53e90f9cca8e021c7d3ad79fb4073d48885ef','Historical helper receipt changed')
    return rows,main,prior,candidate

def require_helper(attempt):
    folder=OUTPUT/('helper-'+str(attempt));receipt=folder/'checks.json';x=json.loads(receipt.read_text())
    require(x['passed'] is True and x['phase']=='helper' and x['manifestSHA256']==sha(BASE/'manifest.json')
        and x['candidateSHA256']==sha(OUTPUT/'candidate-before.json'),'Corrected helper composition differs')
    require(x['details']==dict(helperCompiled=True,legacySSHChecksExecuted=True,newNativeHelperExecuted=False)
        and len(x['artifacts'])==6 and len(x['steps'])==17,'Corrected helper/legacy checks incomplete')
    for row in x['artifacts']:
        p=Path(row['path']);require(p.parent==folder and p.is_file() and not p.is_symlink() and p.stat().st_size==row['bytes'] and sha(p)==row['sha256'],'Corrected helper artifact changed')
    for step in x['steps']:
        require(step['exitCode']==0 and step['reaped'] and step['groupAbsent'] and not step['timedOut'] and not step['killedOwnedGroup'],'Corrected helper child incomplete')
    return x
