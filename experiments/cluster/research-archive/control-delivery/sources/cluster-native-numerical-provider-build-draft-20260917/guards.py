"""Exact final source union and reusable checks; never modifies a workspace."""
import hashlib,json
from pathlib import Path
import source_inventory as inventory
from context import BASE,ELIGIBILITY,ELIGIBILITY_SHA,PRIOR,ACTOR,DRIVER,DRIVER_SHA,NUMERICAL,NUMERICAL_SHA,WORKSPACE,SOURCE,ORIGINAL,OUTPUT,TLS_COMPOSITION,TLS_COMPOSITION_SHA,DRAIN,DRAIN_SHA

def sha(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()
def require(value,message):
    if not value:raise ValueError(message)
def save(path,value):
    with Path(path).open('x') as f:json.dump(value,f,sort_keys=True,indent=2);f.write('\n')
def freeze(root,digest=None):
    if digest is not None:require(sha(root/'manifest.json')==digest,'Frozen manifest differs')
    for row in json.loads((root/'manifest.json').read_text())['members' if root==DRIVER else 'files']:
        p=root/row['path'];require(p.is_file() and not p.is_symlink() and p.stat().st_size==row['bytes'] and sha(p)==row['sha256'],'Frozen source differs: '+str(p))

def verify(*, own=True):
    if own:freeze(BASE)
    freeze(ELIGIBILITY,ELIGIBILITY_SHA);freeze(DRIVER,DRIVER_SHA);freeze(NUMERICAL,NUMERICAL_SHA);freeze(TLS_COMPOSITION,TLS_COMPOSITION_SHA);freeze(DRAIN,DRAIN_SHA)
    for row in json.loads((BASE/'context-pins.json').read_text()):
        p=Path(row['path']);require(p.is_file() and not p.is_symlink() and p.stat().st_size==row['bytes'] and sha(p)==row['sha256'],'Inherited source context changed')
    main=json.loads((ACTOR/'source-before.json').read_text());before=json.loads((ACTOR/'candidate-before.json').read_text())
    correction=json.loads((ELIGIBILITY/'integration.json').read_text())['files']
    require(len(correction)==1,'Exact Service correction required')
    for row in correction:
        require(before[row['path']]=={'sha256':row['beforeSHA256']} and sha(row['sourcePath'])==row['afterSHA256'],'Eligibility correction preimage differs')
        before[row['path']]={'sha256':row['afterSHA256']}
    require(before==json.loads((PRIOR/'candidate-before.json').read_text()) and main==json.loads((PRIOR/'source-before.json').read_text()),'Exact retained c43 inventories differ')
    plan=json.loads((BASE/'integration.json').read_text());rows=plan['files'];candidate=dict(before)
    require(plan['driverManifestSHA256']==DRIVER_SHA and plan['numericalManifestSHA256']==NUMERICAL_SHA,'Source layers differ')
    require(plan['tlsCompositionManifestSHA256']==TLS_COMPOSITION_SHA,'TLS composition identity differs')
    overrides={r['path']:r for r in json.loads((TLS_COMPOSITION/'integration.json').read_text())['overrides']}
    require(len(overrides)==2,'Exactly two TLS composition overrides required')
    preimages={r['path']:r for r in json.loads((DRIVER/'preimages.json').read_text())}
    declared=[]
    for p in sorted((DRIVER/'proposed/provider-swift').rglob('*')):
        if p.is_file():
            name=str(p.relative_to(DRIVER/'proposed'));pre=preimages.get(name)
            value=dict(path=name,sourcePath=str(p),beforeSHA256=pre['sha256'] if pre else None,
                afterSHA256=sha(p),bytes=p.stat().st_size,origin='driver')
            if name in overrides:
                override=overrides[name];require(sha(p)==override['e0ProposedSHA256'],'TLS original proposed source differs')
                value.update(sourcePath=str(TLS_COMPOSITION/'proposed'/name),beforeSHA256=override['beforeSHA256'],
                    afterSHA256=override['afterSHA256'],bytes=override['bytes'],origin='tls-composition')
            declared.append(value)
    for row in json.loads((NUMERICAL/'integration.json').read_text())['files']:
        if row['path'].startswith('provider-swift/') or '/DarkbloomClusterRemote/' in row['path']:
            declared.append(dict(path=row['path'],sourcePath=row['sourcePath'],beforeSHA256=row['preimageSHA256'],
                afterSHA256=row['proposedSHA256'],bytes=row['bytes'],origin='numerical'))
    drain=json.loads((DRAIN/'integration.json').read_text())
    require(plan['drainManifestSHA256']==DRAIN_SHA and drain['baseCandidateSHA256']==sha(PRIOR/'candidate-before.json'),'Endpoint base differs')
    for row in drain['files']:
        p=Path(row['sourcePath']);declared.append(dict(row,bytes=p.stat().st_size,origin='endpoint-drain'))
    require(rows==declared and len(rows)==17 and len({r['path'] for r in rows})==17,'Exact12+4+1 source projection required')
    for row in rows:
        p=Path(row['sourcePath'])
        require(before.get(row['path'],{}).get('sha256')==row['beforeSHA256'] and not p.is_symlink()
                and p.stat().st_size==row['bytes'] and sha(p)==row['afterSHA256'],'Composition preimage/source differs')
        candidate[row['path']]={'sha256':row['afterSHA256']}
    require((len(main),len(before),len(candidate))==(13821,13853,13859),'Exact source counts differ')
    return rows,main,before,candidate

def recheck_sources(candidate,main):
    actual=inventory.inventory(WORKSPACE);observed=inventory.inventory(SOURCE)
    require(actual==candidate and observed==main,'Private or MAIN source/dependencies changed')
    require(json.loads((WORKSPACE/'provider-swift/.build/workspace-state.json').read_text())==
        json.loads((ORIGINAL/'workspace-state-relocated.json').read_text()),'Dependency resolution changed')
    return actual,observed

def require_preserved_cli():
    activation=json.loads((BASE/'activation-1/activation.json').read_text());p=OUTPUT/'prior-binary/darkbloom'
    require(p.is_file() and not p.is_symlink() and p.stat().st_size==activation['priorBinaryBytes']
            and sha(p)==activation['priorBinarySHA256'],'Preserved unqualified prior binary changed')

def require_helper(attempt):
    folder=OUTPUT/('helper-'+str(attempt));x=json.loads((folder/'checks.json').read_text())
    require(x['passed'] is True and x['phase']=='helper' and x['manifestSHA256']==sha(BASE/'manifest.json')
        and x['candidateSHA256']==sha(OUTPUT/'candidate-before.json'),'Current corrected helper differs')
    require(x['details']==dict(helperCompiled=True,legacySSHChecksExecuted=True,newNativeHelperExecuted=False,
        baselineBufferedACKLossReproduced=True,actualOwnerDrainGroupsPassed=4)
        and len(x['artifacts'])==6 and len(x['steps'])==23,'Current helper closure incomplete')
    for row in x['artifacts']:
        p=Path(row['path']);require(p.parent==folder and p.is_file() and not p.is_symlink()
            and p.stat().st_size==row['bytes'] and sha(p)==row['sha256'],'Current helper bytes differ')
    for step in x['steps']:
        require(step['exitCode']==0 and step['reaped'] and step['groupAbsent'] and not step['timedOut'] and not step['killedOwnedGroup'],'Current helper child incomplete')
    require(x['evidencePins'],'Actual helper control evidence absent')
    for row in x['evidencePins']:
        p=Path(row['path']);p.relative_to(folder)
        require(p.is_file() and not p.is_symlink() and p.stat().st_size==row['bytes'] and sha(p)==row['sha256'],'Actual helper control evidence changed')
    return x
