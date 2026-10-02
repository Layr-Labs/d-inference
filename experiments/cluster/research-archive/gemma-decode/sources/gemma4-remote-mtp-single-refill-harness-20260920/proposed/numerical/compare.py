"""Root-only exact closed-output same-build ordinary versus remote MTP replay."""
import argparse,json
from collections import Counter
from pathlib import Path
import numeric_reader as n
from control_contract import validate_control_metrics
from timing_contract import validate_cohort_timing
from refill_contract import validate_wrapper,scope_components,refill_policy

ROOT=Path(__file__).resolve().parent
POLICY='gemma4_verification_packed_m1_dense_packed_head_v1'
TARGET='2468a0cb3049a871f42052f4d9f9380bf12a0792f64c7a29f768559fc7d28785'
ASSISTANT='d8c5fae1f4b7a07376c9f0b92f3ec283ba276d57ec3b675d8cf758a79d73bd34'
EMBEDDING='45259723b22ef7d5c039213763eb57a0711bdc7e897ca112b58821b3d97827a4'

def retained_map(rows):
    result={}
    for row in rows:
        n.require(set(row)=={'path','bytes','sha256'},'Physical retained pin fields')
        n.require(type(row['path']) is str and Path(row['path']).is_absolute(),'Physical retained path')
        n.integer(row['bytes']);n.sha_string(row['sha256'])
        if row['path'] in result:n.equal(result[row['path']],row,'Conflicting physical input pins')
        result[row['path']]=row
    return result

def require_join(retained,path,raw):
    pin=retained.get(str(path))
    n.require(pin is not None and pin['bytes']==len(raw) and pin['sha256']==n.digest(raw),
        'Numerical input differs from accepted bilateral receipt')

def wire_scope(job,wrapper,requests,ordinal):
    return n.digest(('\n'.join(['gemma4_mtp_pull_k2_v1',job['requestIDs'][ordinal],job['membershipEpoch'],
        wrapper['targetNativeSHA256'],wrapper['assistantNativeSHA256'],TARGET,ASSISTANT,EMBEDDING,
        requests[0],str(n.counts(job)['prompt']+1),str(n.counts(job)['frontier'])])+'\n').encode())

def semantic(job):
    value=n.workload(job)
    # Namespace-specific paths are independently bound by each physical receipt;
    # exact prompt bytes and loaded artifact/layout are joined below.
    return {k:v for k,v in value.items() if k not in ('metadataDirectory','promptFile')}

def compare(args):
    inputs=n.Inputs();spec=inputs.json(ROOT/'inputs.json')
    for row in spec['readers']:
        n.require(n.digest(inputs.read(ROOT/row['path']))==row['sha256'],'Frozen arithmetic reader changed')
    for name in ['remoteHarness','localHarness']:
        row=spec[name];n.require(n.digest(inputs.read(row['path']))==row['sha256'],'Declared harness source changed')
    remote_root=Path(spec['remoteHarness']['path']).parent
    for row in inputs.json(spec['remoteHarness']['path'])['members']:
        raw=inputs.read(remote_root/row['path'],empty=(row['bytes']==0))
        n.require(len(raw)==row['bytes'] and n.digest(raw)==row['sha256'],'Remote harness member changed')
    n.require(args.remote_case.parent==remote_root/'cases','Remote case must belong to exact harness')
    activation=inputs.json(remote_root/'activation.json');build=inputs.json(activation['buildReceipt'])
    sources_raw=inputs.read(activation['sourceReceipt']);required=inputs.json(remote_root/'required-native-sources.json')
    n.require(build['exitCode']==0 and build['compilerReaped'] is True and build['groupAbsent'] is True
        and build['gpuExecuted'] is False and build['sourcesSHA256']==activation['sourcesSHA256']==n.digest(sources_raw)
        and n.parse_json(sources_raw)['files']==required['requiredFiles'],'Actual exact compiled source union differs')
    native=inputs.read(args.native_file,128*1024**2,keep=False)
    n.require(native['sha256']==build['nativeSHA256']==activation['nativeSHA256']
        and native['bytes']==build['nativeBytes']==activation['nativeBytes'],'Actual same native differs')
    local_package_raw=inputs.read(args.ordinary_package_manifest);local_package=n.parse_json(local_package_raw)
    matches=[x for x in local_package['files'] if x['path']=='bundle/GemmaResidentBenchmark']
    n.require(local_package['schema']=='gemma4_benchmark_install_v1' and len(matches)==1
        and matches[0]['sha256']==native['sha256'] and matches[0]['bytes']==native['bytes'],'Ordinary package native differs')
    ja,ordinary,_,_,pa,ordinary_physical=n.physical(inputs,args.ordinary_case,native['sha256'],native['bytes'],
        n.digest(local_package_raw),'execute-solo')
    accepted=inputs.json(args.ordinary_case/'comparison.json')
    n.require(accepted['status']=='passed' and accepted['nativeSHA256']==native['sha256']
        and accepted['sourceSHA256']==activation['sourcesSHA256'] and accepted['packageSHA256']==n.digest(local_package_raw)
        and accepted['originalProcessRetired'] is True and accepted['sameEmptyLeaseInode'] is True,'Ordinary physical prerequisite differs')
    physical=inputs.json(args.remote_case/'physical-result.json')
    n.require(physical['schema']=='gemma4_remote_mtp_packed_head_physical_execution_v1' and physical['status']=='passed'
        and physical['nativeSHA256']==native['sha256'] and physical['sourcesSHA256']==activation['sourcesSHA256']
        and physical['targetProjectionPolicy']==POLICY and physical['originalProcessesRetired'] is True
        and physical['sameEmptyLeaseInodes'] is True and physical['aliasRestored'] is True,'Actual bilateral physical prerequisite differs')
    retained=retained_map(physical['retainedInputPins'])
    for path in [remote_root/'activation.json',remote_root/'source-inputs.json',remote_root/'required-native-sources.json',
                 Path(activation['buildReceipt']),Path(activation['sourceReceipt'])]:
        require_join(retained,path,inputs.read(path))
    n.require(inputs.pins[activation['buildReceipt']]['sha256']==activation['buildReceiptSHA256']==physical['buildReceiptSHA256'],
        'Build receipt changed after actual physical acceptance')
    def joined(path,bound=8*1024**2):
        raw=inputs.read(path,bound);require_join(retained,path,raw)
        return n.parse_json(raw)
    pb=args.remote_case/'pair/target';terminal=joined(pb/'terminal.json');remote=terminal['result']
    jb=joined(pb/'job.json',16384);config=joined(pb/'local-mtp.json',16384);wrapper=joined(pb/'remote-mtp.json',16384)
    validate_control_metrics(remote)
    validate_cohort_timing(remote,jb,config)
    validate_wrapper(wrapper,config)
    n.equal(physical['producerRefillPolicy'],refill_policy(wrapper,config),'Physical refill policy differs')
    n.equal(physical['maximumProducerRefillGrant'],1 if 'refillPolicy' in wrapper else 2,'Physical refill grant differs')
    n.equal(physical['maximumProducerLookaheadGrant'],2,'Original overlapped grant differs')
    n.require(terminal['nativeOperation']=='execute-remote-mtp-dense-head' and terminal['status']=='completed'
        and remote['schema']=='gemma4_remote_mtp_target_cohort_v1' and remote['configuration']==wrapper
        and remote['ordinaryJob']==jb and wrapper['embeddingIdentitySHA256']==EMBEDDING,'Actual remote target identity differs')
    n.require(ja['captureEvidence'] is True and jb['captureEvidence'] is False and config['captureEvidence'] is True,
              'Independent full final evidence not admitted')
    n.require(ordinary['schema']=='gemma4_resident_benchmark_result_v1' and ordinary['job']==ja,
        'Ordinary full-reference report identity differs')
    n.equal(semantic(ja),semantic(jb),'Semantic workload/model/build differs')
    c=n.counts(ja)
    n.require(set(ja['requestIDs']).isdisjoint(jb['requestIDs']),'Ordinary and remote reused request IDs')
    prompt_raw=inputs.read(args.prompt_file,131072);prompt=n.parse_json(prompt_raw)
    n.require(n.digest(prompt_raw)==ja['promptFileSHA256']==jb['promptFileSHA256'] and len(prompt)==c['prompt']
        and all(type(x) is int and 0<=x<262144 for x in prompt),'Exact tokenizer packet differs')
    request_sets=[[n.request_hash(job,i,prompt) for i in range(4)] for job in (ja,jb)]
    n.require(ordinary['scopeSHA256']==n.ordinary_scope(ja,ordinary['planSHA256'],request_sets[0]),'Ordinary scope differs')
    depth=config['maximumDraftTokens']
    n.require(type(depth) is int and depth in (1,2),'Exact chosen remote verification depth')
    load=remote['sourceLoad'];plan=load['planSHA256']
    scope=n.text_hash(['gemma4_remote_mtp_cohort_v1',jb['membershipEpoch'],wrapper['targetNativeSHA256'],
        wrapper['assistantNativeSHA256'],EMBEDDING,TARGET,ASSISTANT,plan,jb['promptFileSHA256'],
        'depth='+str(depth),'buffer=5','targetRank=1','assistantRank=0','capture=true']+request_sets[1]+scope_components(wrapper,config)+['targetProjection='+POLICY])
    n.require(scope==remote['scopeSHA256']==physical['scopeSHA256'],'Bilateral dense policy scope differs')
    for key in ('artifactSHA256','configurationSHA256','parameterLayoutSHA256','planSHA256','loadedTensorBytes'):
        n.require(ordinary['sourceLoad'][key]==load[key],'Full registered source/layout differs: '+key)
    for report,collective in ((ordinary,False),(remote,True)):
        n.require(report['nativeExecuted'] is True and report['modelReleased'] is True and report['nativeCacheBytesAfterRelease']==0
            and report['collectiveCreated'] is collective and report['collectiveReleased'] is collective
            and report['warmupRequests']==1 and report['measuredRequests']==3 and len(report['samples'])==4
            and report['sourceLoad']['selectedTensorCount']==1339 and report['sourceLoad']['sourceTensorCount']==1697,
            'Actual full model/request retirement or source coverage differs')
    n.require(remote['denseProjection']['policy']==POLICY and remote['denseProjection']['expectedDenseModules']==235
        and remote['denseProjection']['expectedTiedHeads']==1 and remote['denseProjection']['serialHeadLogicalBytes']==4194304
        and remote['denseProjection']['gatheredOverrideEnabled'] is False
        and remote['denseProjection']['singleRowOverrideEnabled'] is False
        and remote['denseProjection']['wholeModelNumericsQualified'] is False,
        'Actual target projection policy differs')
    sidecars=[n.Sidecars(inputs,pa,ordinary['files']),n.Sidecars(inputs,pb,remote['files'])]
    total=0;counts=Counter();summaries=[]
    for ordinal,(a,b) in enumerate(zip(ordinary['samples'],remote['samples'])):
        for sample,job,requests,report in ((a,ja,request_sets[0],ordinary),(b,jb,request_sets[1],remote)):
            n.require(sample['requestID']==job['requestIDs'][ordinal] and sample['requestStateRetired'] is True
                and sample['requestSHA256']==requests[ordinal] and sample['ordinal']==ordinal
                and sample['warmup'] is (ordinal==0) and sample['committedTokens']==c['frontier'],'Fresh target request/frontier differs')
            tokens=sample['selectedTokenIDs'];n.require(len(tokens)==c['output'] and all(type(x) is int and 0<=x<262144 for x in tokens),'Token bounds')
            n.require(sample['selectedTokenIDsSHA256']==n.digest(','.join(map(str,tokens)).encode()),'Token digest differs')
            n.binding(sample['binding'],report['sourceLoad'],job)
        n.require(b['scopeSHA256']==wire_scope(jb,wrapper,request_sets[1],ordinal),'Actual per-request pull scope differs')
        n.equal(a['selectedTokenIDs'],b['selectedTokenIDs'],'Remote greedy output differs')
        n.equal({k:v for k,v in a['binding'].items() if k!='readAccountingSHA256'},
                {k:v for k,v in b['binding'].items() if k!='readAccountingSHA256'},'Observed target state layout differs')
        evidence=b['evidence'];n.require(evidence['capturedBeforeRequestRetirement'] is True and evidence['outsideGenerationTiming'] is True,'Remote capture lifecycle differs')
        n.require(n.row(a['finalRow'],sidecars[0],ordinal,a['selectedTokenIDs'][-1])
            ==n.row(evidence['finalRow'],sidecars[1],ordinal,b['selectedTokenIDs'][-1]),'Exact complete final row differs')
        states=[n.state(ev['finalState'],sample['binding'],sc,ordinal,c['frontier']) for ev,sample,sc in zip((a,evidence),(a,b),sidecars)]
        n.require(states[0]==states[1],'Exact full90 state differs at request '+str(ordinal));total+=sum(len(x[3]) for x in states[0].values())
        widths=b['verificationWidths'];accepted=b['acceptedPrefixes']
        n.require(widths and widths[0]==1 and len(widths)==len(accepted)
            and all(type(w) is int and 1<=w<=depth+1 for w in widths)
            and all(type(k) is int and 0<=k<w for k,w in zip(accepted,widths))
            and len(widths)+sum(accepted)==c['decode'] and b['offeredProposals']==sum(w-1 for w in widths)
            and b['acceptedProposals']==sum(accepted),'Accepted prefix accounting differs')
        counts.update(widths);summaries.append(dict(ordinal=ordinal,tokens=a['selectedTokenIDs'],verificationWidths=widths,
            acceptedPrefixes=accepted,finalStateSHA256=a['finalState']['fingerprint']))
    n.require(any(w>1 for w in counts),'No rectangular verification was exercised')
    for sc in sidecars:n.require(sc.used==set(sc.files),'Unjoined final evidence')
    inputs.recheck()
    return dict(schema='gemma4_output_bound_remote_packed_head_mtp_numerical_comparison_v1',status='passed',nativeSHA256=native['sha256'],
        sourcesSHA256=activation['sourcesSHA256'],targetProjectionPolicy=POLICY,producerRefillPolicy=refill_policy(wrapper,config),requestsCompared=4,promptTokens=c['prompt'],outputTokens=c['output'],generatedTokensCompared=c['allGeneratedTokens'],
        fullFinalRowsCompared=4,stateComponentsCompared=360,stateBytesCompared=total,nativeRowsAndStateExactlyEqual=True,
        actualObservedWidths=dict(counts),samples=summaries,ordinaryPhysical=ordinary_physical,
        remotePhysicalReceipt=inputs.pins[str(args.remote_case/'physical-result.json')],sameBuildFinalRemoteNumericsQualified=True,
        allIntermediateRowsCompared=False,allRollbackPrefixesQualified=False,longContextQualified=False,performanceQualified=False,
        encryptedRDMAEstablished=False,toleranceApplied=False,retainedInputPins=list(inputs.pins.values()))

def main():
    p=argparse.ArgumentParser(allow_abbrev=False)
    for name in ['ordinary-case','ordinary-package-manifest','remote-case','native-file','prompt-file','output']:
        p.add_argument('--'+name,type=Path,required=True)
    args=p.parse_args()
    for path in vars(args).values():n.require(path.is_absolute() and path.parent.resolve()==path.parent,'Canonical absolute paths required')
    n.require(not args.output.exists(),'Create-only numerical output')
    result=compare(args)
    with args.output.open('x') as f:json.dump(result,f,indent=2,allow_nan=False);f.write('\n')
    print(json.dumps(dict(status='passed',fullRows=4,stateComponents=360,output=str(args.output))))

if __name__=='__main__':main()
