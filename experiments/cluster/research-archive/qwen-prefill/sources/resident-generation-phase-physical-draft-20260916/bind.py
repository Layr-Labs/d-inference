"""Create-only binding plus pure argument controls; no model, GPU, network or copies."""
from pathlib import Path
import argparse,base64,copy,hashlib,importlib,json,os,sys
from capacity import derive
BASE=Path(__file__).resolve().parent
ROOT=BASE.parent
NATIVE=ROOT/'resident-generation-phase-native-draft-20260916/Build/runtime-bundle-1'
NATIVE_SHA='649544175053810f804a662232bdfce43d5321b8fda0b3618959d94f1ad60182'
BUNDLE_SHA='276e493502a0cfe94aa7264ffdf7a4d0d0d035187ed0526dbd57965c6b51da54'
OLD_REMOTE='/Users/developer/DarkbloomDev/qwen27b-8k-lookahead-owner-validation-20260915'

def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def pin(p):return dict(path=str(p),bytes=p.stat().st_size,sha256=sha(p))
def raw(value):return (json.dumps(value,sort_keys=True,separators=(',',':'))+'\n').encode()
def save(p,value):
    p.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
    with p.open('xb') as f:f.write(value if isinstance(value,bytes) else raw(value))
def verify_small_manifest(p):
    x=json.loads((p/'manifest.json').read_bytes())
    for row in x['members']:
        f=p/row['path'];assert f.stat().st_size==row['bytes'] and sha(f)==row['sha256']
def main():
    ap=argparse.ArgumentParser(allow_abbrev=False)
    ap.add_argument('--controller-attempt',type=int,required=True)
    ap.add_argument('--controller-receipt-sha256',required=True)
    args=ap.parse_args();assert 1<=args.controller_attempt<=99
    verify_small_manifest(BASE)
    control=BASE/'Controller'/('build-'+str(args.controller_attempt))
    assert sha(control/'receipt.json')==args.controller_receipt_sha256
    cr=json.loads((control/'receipt.json').read_bytes());assert cr['passed'] and cr['sourcePinsUnchanged']
    cb=control/'bundle';assert sha(cb/'bundle.json')==cr['bundleSHA256']
    host=json.loads((control/'budget-run.stdout').read_bytes());assert sha(control/'budget-run.stdout')==cr['hostBudgetSHA256']
    assert sha(NATIVE/'bundle.json')==BUNDLE_SHA
    nb=json.loads((NATIVE/'bundle.json').read_bytes());lineage=json.loads((BASE/'inputs/lineage.json').read_bytes())
    assert nb['sourceSnapshotSHA256']==lineage['sourceSnapshotSHA256'] and nb['dependencySnapshotSHA256']==lineage['dependencySnapshotSHA256']
    native_rows={x['path']:x for x in nb['files']};assert native_rows['darkbloom-cluster-worker']['sha256']==NATIVE_SHA
    # Binding uses already-packaged pins, never a bulk artifact read. Root's exact
    # artifact check/copy/preflight hashes every declared byte before execution.
    for row in nb['files']:assert (NATIVE/row['path']).stat().st_size==row['bytes']
    cfiles=json.loads((cb/'bundle.json').read_bytes())['files']
    for row in cfiles:assert (cb/row['path']).stat().st_size==row['bytes'] and sha(cb/row['path'])==row['sha256']
    # Pure worker argument validation must precede any executable run binding.
    from check_arguments import run as check_arguments
    argument_attempt=str(args.controller_attempt)
    assert check_arguments(argument_attempt)['passed']
    argument_receipt=BASE/('arguments-'+argument_attempt)/'receipt.json'
    ids=json.loads((BASE/'inputs/run-identities.json').read_bytes())
    prompt=(BASE/'inputs/prompt.ids.json').read_bytes();tokens=json.loads(prompt)
    expected=json.loads((BASE/'inputs/expected-token-ids.json').read_bytes())
    assert len(tokens)==8192 and len(expected)==128 and sha(BASE/'inputs/prompt.ids.json')=='ee6caf0be6391e00ec41df930f0fd6351613969622cbb247b1b4bdaf69afe997'
    outputs=[]
    for policy,label in [('serial','serial'),('oneChunkLookahead','lookahead')]:
        folder=BASE/label;folder.mkdir(mode=0o700)
        runid=ids[label];remote='/Users/developer/DarkbloomDev/qwen27b-phase-'+label+'-validation-20260916'
        cap=derive(host,policy)
        # Existing policy-specific expected preparer and catalog are byte exact.
        comp=BASE/('comparison-serial' if policy=='serial' else 'comparison')
        for name in ['audit_common','audit_scope','audit_generation','audit_candidate','audit_state','audit_reference','recorded_math','snapshot','prepare_expected']:sys.modules.pop(name,None)
        sys.path.insert(0,str(comp));prepare=importlib.import_module('prepare_expected');common=importlib.import_module('audit_common')
        req=json.loads((BASE/'inputs/request.json').read_bytes());req['requestID']=runid['requestID']
        metadata=json.loads((BASE/'inputs/recording-metadata.json').read_bytes());metadata['nativeBinarySHA256']=NATIVE_SHA
        identity=json.loads((BASE/'templates/provenance/expected-identity.json').read_bytes())
        agreement=prepare.expected(raw(req),raw(metadata),prompt,runid['membershipEpoch'],identity['storageCommitmentSHA256'],identity['arithmeticSHA256'])
        context=common.request_context(prompt,req['requestID'],importlib.import_module('audit_scope').pinned_scope(req,metadata))
        agreement_sha=common.agreement(agreement,context);sys.path.pop(0)
        save(folder/'expected-agreement.json',agreement);save(folder/'capacity.json',cap)
        save(folder/'inputs/request.json',req)
        save(folder/'inputs/prompt.ids.json',prompt);save(folder/'inputs/expected-token-ids.json',expected)
        controller=json.loads((BASE/'templates/configuration/controller.json').read_bytes())
        controller.update(requestID=runid['requestID'],membershipEpoch=runid['membershipEpoch'],clusterID='qwen27b-phase-'+runid['membershipEpoch'])
        for peer in controller['peers']:peer['installedOwner']=remote+'/darkbloom-owner-qualification'
        owner_configs=[]
        for rank in [0,1]:
            owner=json.loads((BASE/f'templates/configuration/owner-rank{rank}.json').read_bytes())
            template=json.loads(base64.b64decode(owner['readyTemplateBase64'],validate=True))
            template['ready']['requestCapacityBytes']=cap['ranks'][rank]['totalReservedBytes']
            for peer in template['ready']['identity']['peers']:peer['buildSHA256']=NATIVE_SHA
            owner['readyTemplateBase64']=base64.b64encode(raw(template)).decode()
            owner['clusterID']=controller['clusterID'];owner['workerExecutable']=remote+'/darkbloom-cluster-worker'
            for key,value in owner['workerEnvironment'].items():owner['workerEnvironment'][key]=value.replace(OLD_REMOTE,remote)
            if policy=='serial':owner['workerEnvironment'].pop('DARKBLOOM_BENCHMARK_PREFILL_POLICY')
            else:assert owner['workerEnvironment']['DARKBLOOM_BENCHMARK_PREFILL_POLICY']=='one_chunk_lookahead_v1'
            if rank==0:controller['readyTemplateBase64']=owner['readyTemplateBase64']
            owner_configs.append(owner);save(folder/f'configuration/owner-rank{rank}.json',owner)
            phase_identity={k:agreement[k] for k in ['requestID','membershipEpoch','requestFingerprint','profileFingerprint','sourceConfigurationSHA256','artifactAggregateSHA256','storageCommitmentSHA256','planFingerprint','numericalPolicySHA256']}
            phase_identity.update(agreementFingerprint=agreement_sha,stageFingerprint=agreement['stageFingerprints'][rank],buildSHA256=NATIVE_SHA,rank=rank,promptCount=8192,chunkSize=512,outputCount=128,prefillPolicy=policy)
            save(folder/f'expected-rank{rank}.json',dict(identity=phase_identity,expectedTokenIDs=expected))
        metadata['readyTemplatesBase64']=[owner['readyTemplateBase64'] for owner in owner_configs]
        save(folder/'inputs/plan.json',metadata)
        save(folder/'configuration/controller.json',controller)
        save(folder/'configuration/matrix.json',(BASE/'templates/configuration/matrix.json').read_bytes())
        for file in sorted((BASE/'templates').rglob('*.py')):
            rel=file.relative_to(BASE/'templates');text=file.read_text().replace(OLD_REMOTE,remote)
            if str(rel)=='run_physical.py':
                text=text.replace('ROOT = BASE.parent\n','ROOT = BASE.parent.parent\n')
                text=text.replace("CONTROLLER = ROOT / 'cluster-owner-diagnostic-drain-draft-20260915/local-bundle/owner-controller'",'CONTROLLER = Path('+repr(str(cb/'owner-controller'))+')')
            if str(rel)=='read_sidecar_remote.py':
                text=text.replace('c7517799-2a77-49fa-af9c-2b4f662bf76c',runid['requestID']).replace('read_fixed(SIDECAR, 16*1024**2)','read_fixed(SIDECAR, 256*1024)')
            save(folder/rel,text.encode())
        deployment=json.loads((BASE/'templates/deployment.json').read_bytes())
        deployment['localController']=next(dict(path=str(cb/x['path']),bytes=x['bytes'],sha256=x['sha256']) for x in cfiles if x['path']=='owner-controller')
        deployment['localControlBundle']=pin(cb/'bundle.json')
        for rank,value in enumerate(deployment['ranks']):
            value['remoteRoot']=remote
            for row in value['files']:
                name=row['path']
                if name in native_rows:row.update(source=str(NATIVE/name),bytes=native_rows[name]['bytes'],sha256=native_rows[name]['sha256'],role='phase_native' if name=='darkbloom-cluster-worker' else 'matched_native_resource')
                elif name=='owner.json':
                    source=folder/f'configuration/owner-rank{rank}.json';row.update(source=str(source),bytes=source.stat().st_size,sha256=sha(source))
                elif name=='matrix.json':
                    source=folder/'configuration/matrix.json';row.update(source=str(source),bytes=source.stat().st_size,sha256=sha(source))
                elif (folder/name).is_file():
                    source=folder/name;row.update(source=str(source),bytes=source.stat().st_size,sha256=sha(source))
            copyplan=dict(schema='qwen27b_load_operands_copy_only_tree_v1',files={('owner/'+x['path']):dict(source=x['source'],bytes=x['bytes'],sha256=x['sha256'],mode=int(x['mode'],8)) for x in value['files']})
            assert len(copyplan['files'])==14;save(folder/f'deployment-rank{rank}.json',copyplan)
        save(folder/'deployment.json',deployment)
        save(folder/'binding.json',dict(schema='resident_phase_physical_binding_v1',policy=policy,remoteRoot=remote,**runid,
            nativeBundle=pin(NATIVE/'bundle.json'),controllerBundle=pin(cb/'bundle.json'),controllerReceipt=pin(control/'receipt.json'),
            referenceSHA256='1922793ab2f252d52b3729efd4222220935bd1d046c6649fc71afded1ad70305',
            expectedIDs=pin(folder/'inputs/expected-token-ids.json'),controllerConfiguration=pin(folder/'configuration/controller.json'),
            sourceManifest=pin(BASE/'manifest.json'),phaseValidator=pin(BASE/'validate_phase.py'),hostBudgetEvidence=pin(control/'budget-run.stdout'),nativeArgumentControls=pin(argument_receipt),
            noCrossHostClockMath=True,independentNumericalComparisonPerformed=False))
        pins=[pin(f) for f in sorted(folder.rglob('*')) if f.is_file()]
        pins.extend(dict(path=str(cb/x['path']),bytes=x['bytes'],sha256=x['sha256']) for x in cfiles)
        # Exact remote payload closure is rehashed by copy and preflight, not all
        # repeatedly in the timed parent. Parent pins local control/source only.
        save(folder/'run-pins.json',dict(files=pins))
        members={str(f.relative_to(folder)):{k:v for k,v in pin(f).items() if k!='path'} for f in sorted(folder.rglob('*')) if f.is_file()}
        save(folder/'manifest.json',dict(schema='resident_phase_physical_case_v1',files=members,modelOrRemoteExecuted=False))
        outputs.append(dict(policy=policy,path=str(folder),manifestSHA256=sha(folder/'manifest.json')))
    save(BASE/'bound-runs.json',dict(schema='resident_phase_bound_runs_v1',runs=outputs,automaticExecution=False))
    print(json.dumps(outputs))
if __name__=='__main__':os.umask(0o077);main()
