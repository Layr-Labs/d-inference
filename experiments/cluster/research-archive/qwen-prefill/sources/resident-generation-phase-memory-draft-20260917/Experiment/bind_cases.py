"""Create-only C256 cases after an actual native build and a separately reviewed C256 reference.

This makes no subprocess, model or network call. Physical execution stays root-owned.
"""
from pathlib import Path
import argparse,base64,copy,hashlib,importlib,json,os,sys
from capacity import derive
from bind_reference import reference
from prepare_inputs import REQUEST,EPOCHS,REMOTE,PROMPT,expected_packet
from physical_evidence import read,parse,require,pin,digest
BASE=Path(__file__).resolve().parent
DRAFT=BASE.parent
ROOT=DRAFT.parent
OLD=ROOT/'resident-generation-phase-physical-draft-20260916'
BUILD=DRAFT/'Build'
CONTROLLER=OLD/'Controller/build-1/bundle'
OLD_REMOTE='/Users/developer/DarkbloomDev/qwen27b-8k-lookahead-owner-validation-20260915'

def raw(x):return (json.dumps(x,sort_keys=True,separators=(',',':'))+'\n').encode()
def save(p,x):
    p.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
    with p.open('xb') as f:f.write(x if isinstance(x,bytes) else raw(x))
def verify_manifest(folder):
    for row in parse(read(folder/'manifest.json',4*1024**2))['members']:
        value=read(folder/row['path'],4*1024**2)
        require(len(value)==row['bytes'] and digest(value)==row['sha256'],'Frozen source changed: '+row['path'])

def main():
    p=argparse.ArgumentParser(allow_abbrev=False)
    p.add_argument('--inputs',type=Path,required=True)
    p.add_argument('--native-attempt',type=int,required=True);p.add_argument('--cpu-attempt',type=int,required=True)
    p.add_argument('--reference-returned',type=Path,required=True);p.add_argument('--reference-review',type=Path,required=True)
    p.add_argument('--reference-review-sha256',required=True)
    a=p.parse_args();require(1<=a.native_attempt<=99 and 1<=a.cpu_attempt<=99,'Bounded attempts required')
    verify_manifest(DRAFT);verify_manifest(OLD)
    for x in parse(read(BASE/'input-pins.json')):require(pin(Path(x['path']))==x,'Retained input changed')
    plan=parse(read(a.inputs/'case-plan.json'));request=parse(read(a.inputs/'request.json'));prompt=read(a.inputs/'prompt.ids.json',65536)
    job,wanted_request=expected_packet()
    require(plan['requestID']==REQUEST and digest(prompt)==PROMPT and request==wanted_request
        and parse(read(a.inputs/'reference-job.json'))==job and plan['requestSHA256']==digest(read(a.inputs/'request.json'))
        and plan['referenceJobSHA256']==digest(read(a.inputs/'reference-job.json')),
        'Prepared C256 packet differs')
    expected_tokens,reference_pins=reference(a.inputs,a.reference_returned,a.reference_review,a.reference_review_sha256)
    native=BUILD/('runtime-bundle-'+str(a.native_attempt));nb=parse(read(native/'bundle.json'))
    build=BUILD/('native-'+str(a.native_attempt))/'receipt.json';br=parse(read(build))
    require(br['passed'] is True and nb['buildReceiptSHA256']==digest(read(build)),'Actual native build required')
    require(nb['sourceSnapshotSHA256']==digest(read(BUILD/'source-snapshot-1.json',4*1024**2)) and
        nb['dependencySnapshotSHA256']==digest(read(BUILD/'dependency-snapshot-1.json',4*1024**2)),'Native source/dependency binding differs')
    native_rows={x['path']:x for x in nb['files']};native_sha=native_rows['darkbloom-cluster-worker']['sha256']
    require(native_sha==br['binarySHA256'],'Native binary build binding differs')
    # No binary read here. Actual hash/identity checks are mandatory in root copy/preflight.
    for n,row in native_rows.items():require((native/n).stat().st_size==row['bytes'],'Packaged native size differs')
    args_receipt=BUILD/('arguments-'+str(a.native_attempt))/'receipt.json';ar=parse(read(args_receipt))
    require(ar['passed'] is True and ar['nativeSHA256']==native_sha,'Actual pure native argument controls required')
    cpu=BUILD/('cpu-'+str(a.cpu_attempt));cr=parse(read(cpu/'receipt.json'))
    host=parse(read(cpu/'budget-run.stdout'))
    require(cr['passed'] is True and cr['hostBudgetSHA256']==digest(read(cpu/'budget-run.stdout')) and
        cr['frozenSourceManifestSHA256']==digest(read(DRAFT/'manifest.json',4*1024**2)),'Actual host budget fixture binding differs')
    controls=parse(read(CONTROLLER/'bundle.json'))['files']
    for x in controls:require((CONTROLLER/x['path']).stat().st_size==x['bytes'],'Controller artifact size differs')
    outputs=[]
    for name,policy in [('serial','serial'),('lookahead','oneChunkLookahead')]:
        case=BASE/name;case.mkdir(mode=0o700);remote=REMOTE+'-'+name+'-20260917';epoch=EPOCHS[name];cap=derive(host,policy)
        comp=OLD/('comparison-serial' if name=='serial' else 'comparison')
        for m in ['audit_common','audit_scope','audit_generation','audit_candidate','audit_state','audit_reference','recorded_math','snapshot','prepare_expected']:
            sys.modules.pop(m,None)
        sys.path.insert(0,str(comp));prep=importlib.import_module('prepare_expected');common=importlib.import_module('audit_common')
        metadata=parse(read(OLD/'inputs/recording-metadata.json'));metadata['nativeBinarySHA256']=native_sha
        provenance=parse(read(OLD/'templates/provenance/expected-identity.json'))
        agreement=prep.expected(raw(request),raw(metadata),prompt,epoch,provenance['storageCommitmentSHA256'],provenance['arithmeticSHA256'])
        context=common.request_context(prompt,REQUEST,importlib.import_module('audit_scope').pinned_scope(request,metadata))
        agreement_sha=common.agreement(agreement,context);sys.path.pop(0)
        cfg=parse(read(OLD/'templates/configuration/controller.json'));cfg.update(requestID=REQUEST,membershipEpoch=epoch,
            clusterID='qwen27b-phase-memory-'+epoch,chunkSize=256,expectedTokenIDs=expected_tokens,promptTokenIDs=parse(prompt))
        for peer in cfg['peers']:peer['installedOwner']=remote+'/darkbloom-owner-qualification'
        owner_configs=[]
        for rank in [0,1]:
            owner=parse(read(OLD/f'templates/configuration/owner-rank{rank}.json'))
            template=parse(base64.b64decode(owner['readyTemplateBase64'],validate=True))
            template['ready']['requestCapacityBytes']=cap['ranks'][rank]['readyCapacityBytes']
            for peer in template['ready']['identity']['peers']:peer['buildSHA256']=native_sha
            owner['readyTemplateBase64']=base64.b64encode(raw(template)).decode();owner['clusterID']=cfg['clusterID']
            owner['workerExecutable']=remote+'/darkbloom-cluster-worker'
            owner['workerEnvironment']={k:v.replace(OLD_REMOTE,remote) for k,v in owner['workerEnvironment'].items()}
            if name=='serial':owner['workerEnvironment'].pop('DARKBLOOM_BENCHMARK_PREFILL_POLICY')
            else:require(owner['workerEnvironment']['DARKBLOOM_BENCHMARK_PREFILL_POLICY']=='one_chunk_lookahead_v1','Policy changed')
            require(owner['maximumLifetimeSeconds']==300 and owner['stageCut']==16,'Owner scope changed')
            if rank==0:cfg['readyTemplateBase64']=owner['readyTemplateBase64']
            owner_configs.append(owner);save(case/f'configuration/owner-rank{rank}.json',owner)
            identity={k:agreement[k] for k in ['requestID','membershipEpoch','requestFingerprint','profileFingerprint',
                'sourceConfigurationSHA256','artifactAggregateSHA256','storageCommitmentSHA256','planFingerprint','numericalPolicySHA256']}
            identity.update(agreementFingerprint=agreement_sha,stageFingerprint=agreement['stageFingerprints'][rank],buildSHA256=native_sha,
                rank=rank,promptCount=8192,chunkSize=256,outputCount=128,prefillPolicy=policy)
            save(case/f'expected-rank{rank}.json',dict(identity=identity,expectedTokenIDs=expected_tokens))
        metadata['readyTemplatesBase64']=[x['readyTemplateBase64'] for x in owner_configs]
        for n,v in [('expected-agreement.json',agreement),('capacity.json',cap),('inputs/request.json',request),
            ('inputs/prompt.ids.json',prompt),('inputs/expected-token-ids.json',expected_tokens),('inputs/plan.json',metadata),
            ('configuration/controller.json',cfg),('configuration/matrix.json',read(OLD/'templates/configuration/matrix.json'))]:save(case/n,v)
        for f in sorted((OLD/'templates').rglob('*.py')):
            rel=f.relative_to(OLD/'templates');text=f.read_text().replace(OLD_REMOTE,remote)
            if str(rel)=='run_physical.py':
                text=text.replace('ROOT = BASE.parent\n','ROOT = BASE.parent.parent.parent\n')
                text=text.replace("CONTROLLER = ROOT / 'cluster-owner-diagnostic-drain-draft-20260915/local-bundle/owner-controller'",
                    'CONTROLLER = Path('+repr(str(CONTROLLER/'owner-controller'))+')')
            if str(rel)=='read_sidecar_remote.py':
                text=text.replace('c7517799-2a77-49fa-af9c-2b4f662bf76c',REQUEST).replace('read_fixed(SIDECAR, 16*1024**2)','read_fixed(SIDECAR, 1024*1024)')
            save(case/rel,text.encode())
        deploy=parse(read(OLD/'templates/deployment.json'))
        deploy['localController']=next(dict(path=str(CONTROLLER/x['path']),bytes=x['bytes'],sha256=x['sha256']) for x in controls if x['path']=='owner-controller')
        deploy['localControlBundle']=pin(CONTROLLER/'bundle.json')
        for rank,value in enumerate(deploy['ranks']):
            value['remoteRoot']=remote
            for row in value['files']:
                n=row['path']
                if n in native_rows:row.update(source=str(native/n),bytes=native_rows[n]['bytes'],sha256=native_rows[n]['sha256'],role='phase_memory_native' if n=='darkbloom-cluster-worker' else 'matched_native_resource')
                elif n in ['owner.json','matrix.json']:
                    f=case/(f'configuration/owner-rank{rank}.json' if n=='owner.json' else 'configuration/matrix.json');row.update(source=str(f),bytes=f.stat().st_size,sha256=digest(read(f)))
                elif (case/n).is_file():
                    f=case/n;row.update(source=str(f),bytes=f.stat().st_size,sha256=digest(read(f)))
            save(case/f'deployment-rank{rank}.json',dict(schema='qwen27b_load_operands_copy_only_tree_v1',files={
                'owner/'+x['path']:dict(source=x['source'],bytes=x['bytes'],sha256=x['sha256'],mode=int(x['mode'],8)) for x in value['files']}))
        save(case/'deployment.json',deploy)
        save(case/'binding.json',dict(schema='resident_phase_memory_physical_binding_v1',policy=policy,remoteRoot=remote,
            requestID=REQUEST,membershipEpoch=epoch,nativeBundle=pin(native/'bundle.json'),controllerBundle=pin(CONTROLLER/'bundle.json'),
            controllerReceipt=pin(OLD/'Controller/build-1/receipt.json'),reference=reference_pins,
            expectedIDs=pin(case/'inputs/expected-token-ids.json'),controllerConfiguration=pin(case/'configuration/controller.json'),
            sourceManifest=pin(DRAFT/'manifest.json'),phaseValidator=pin(BASE/'validate_phase_memory.py'),
            hostBudgetEvidence=pin(cpu/'budget-run.stdout'),nativeArgumentControls=pin(args_receipt),
            noCrossHostClockMath=True,independentNumericalComparisonPerformed=False))
        pins=[pin(f) for f in sorted(case.rglob('*')) if f.is_file()]
        pins.extend(dict(path=str(CONTROLLER/x['path']),bytes=x['bytes'],sha256=x['sha256']) for x in controls)
        save(case/'run-pins.json',dict(files=pins))
        files={str(f.relative_to(case)):{k:v for k,v in pin(f).items() if k!='path'} for f in sorted(case.rglob('*')) if f.is_file()}
        save(case/'manifest.json',dict(schema='resident_phase_physical_case_v1',files=files,modelOrRemoteExecuted=False))
        outputs.append(dict(policy=policy,path=str(case),manifestSHA256=digest(read(case/'manifest.json'))))
    save(BASE/'bound-runs.json',dict(schema='resident_phase_bound_runs_v1',runs=outputs,automaticExecution=False))
    print(json.dumps(outputs))
if __name__=='__main__':os.umask(0o077);main()
