"""Exact prior-MTP versus memo-MTP replay. Never promotes MTP versus ordinary."""
import argparse
from collections import Counter
import json
from pathlib import Path
from replay import (Inputs,Sidecars,binding,digest,equal,integer,ordinary_scope,parse_json,
                    physical,request_hash,require,row,state,text_hash,workload)
from local_mtp_contract import validate_result

ROOT=Path(__file__).resolve().parent
BASE=ROOT.parent
ARMS=[dict(name='previousMTP',harness='harness-local-mtp-v2',case='p128-mtp2-qualification-1',
    native='eaeb7eecd1f135f75ce53919ca0d517b743411bda0224f190f0f8158413d19e7',
    source='6d48fef4e0b855f0954467969e9080312ad8c461cd283eee8653fcdb298c6154',
    build='c0cab5020873244096cc8cf07807021f113297d87344f3c576843ac9254d725f',operation='qualify-mtp-conditioning'),
    dict(name='memoMTP',harness='harness-local-mtp-bound-memo',case='p128-mtp2-memo-capture-1',
    native='ffb80547d4715dad6a212efc9c599389357a9d2601c18ed1483482cf0d2772fa',
    source='6288a214f78f6082fe16824c0ef554150a8328dc08dcaffce0ae3d35d55d8dfb',
    build='e60fac5ae974894eb6c97400d7b00fe604a7ce96932bcb9611d1f717c08ce260',operation='execute-local-mtp')]
CHANGED={'Gemma4BenchmarkEntry.swift','Gemma4BenchmarkResourceOwner.swift','Gemma4LocalMTPDriver.swift',
         'Gemma4MTPAuxiliaryOwner.swift','Gemma4OwnedMTPVerification.swift'}


def source_check(inputs):
    manifest=inputs.json(ROOT/'source-inputs.json')
    for pin in manifest['members']:
        raw=inputs.read(ROOT/pin['path']);require(digest(raw)==pin['sha256'] and len(raw)==pin['bytes'],'Comparator source changed')


def provenance(inputs,arm):
    harness=BASE/arm['harness'];case=harness/'cases'/arm['case']
    comparison=inputs.json(case/'comparison.json')
    require(comparison['schema']=='gemma4_decode_cohort_physical_execution_v1' and comparison['status']=='passed'
        and comparison['nativeOperation']==arm['operation'] and comparison['nativeSHA256']==arm['native']
        and comparison['sourceSHA256']==arm['source'] and comparison['buildReceiptSHA256']==arm['build']
        and comparison['modelNumericalCorrectnessQualified'] is False and comparison['performanceQualified'] is False
        and comparison['originalProcessRetired'] is True and comparison['sameEmptyLeaseInode'] is True
        and comparison['aliasUsed'] is False,'Actual physical comparison failed or scope changed')
    action_root=harness/'root-actions'/('compare-'+arm['case'])
    action=inputs.json(action_root/'receipt.json')
    require(action['action']=='compare' and action['status']=='passed' and action['exitCode']==0
        and action['reaped'] is True and action['groupAbsent'] is True and action['killedOwnedGroup'] is False
        and action['argv']==['/usr/bin/python3','-B',str(harness/'compare.py'),'--case',arm['case'],'--output',str(case/'comparison.json')],
        'Actual physical comparator child did not complete')
    for stream in ('stdout','stderr'):
        raw=inputs.read(action_root/stream,16384,empty=stream=='stderr')
        require(digest(raw)==action[stream+'SHA256'] and len(raw)==action[stream+'Bytes'],'Comparator execution stream changed')
        if stream=='stderr':require(raw==b'','Physical comparator stderr')
    source_manifest=inputs.json(harness/'source-inputs.json')
    require(inputs.pins[str(harness/'source-inputs.json')]['sha256']==comparison['sourceManifestSHA256']==action['sourceManifestSHA256'],
        'Physical source manifest join')
    for pin in source_manifest['members']:
        raw=inputs.read(harness/pin['path'],2*1024**2)
        require(digest(raw)==pin['sha256'] and len(raw)==pin['bytes'],'Frozen physical helper changed')
    activation=inputs.json(harness/'activation.json')
    require(inputs.pins[str(harness/'activation.json')]['sha256']==comparison['activationSHA256']==action['activationSHA256']
        and activation['nativeSHA256']==arm['native'] and activation['sourcesSHA256']==arm['source']
        and activation['buildReceiptSHA256']==arm['build'],'Activation identity differs')
    build_path=Path(activation['buildReceipt']);source_path=Path(activation['sourceReceipt'])
    build=inputs.json(build_path);source=inputs.json(source_path)
    require(inputs.pins[str(build_path)]['sha256']==arm['build'] and inputs.pins[str(source_path)]['sha256']==arm['source']
        and build['exitCode']==0 and build['compilerReaped'] is True and build['groupAbsent'] is True
        and build['gpuExecuted'] is False and build['nativeSHA256']==arm['native']
        and build['nativeBytes']==activation['nativeBytes'] and build['sourcesSHA256']==arm['source'],'Actual native/source build differs')
    native=inputs.read(harness/'deployment/bundle/GemmaResidentBenchmark',64*1024**2,keep=False)
    require(native['sha256']==arm['native'] and native['bytes']==build['nativeBytes'],'Preserved actual native differs')
    package_raw=inputs.read(harness/'deployment/package.json');package=parse_json(package_raw)
    require(digest(package_raw)==comparison['packageSHA256'],'Physical package join')
    rows={x['path']:x for x in package['files']};require(len(rows)==len(package['files']),'Duplicate package entries')
    require(rows['bundle/GemmaResidentBenchmark']==dict(path='bundle/GemmaResidentBenchmark',sha256=arm['native'],bytes=build['nativeBytes']),
        'Native package identity')
    data=physical(inputs,case,arm['native'],build['nativeBytes'],digest(package_raw),arm['operation'])
    job,result,config,config_sha,returned,physical_receipt=data
    require(inputs.json(case/'operation.json')==dict(operation=arm['operation']) and comparison['nativeScopeSHA256']==result['scopeSHA256']
        and comparison['configSHA256']==config_sha,'Actual native scope/operation differs')
    validate_result(result,job,config,config_sha,arm['operation'])
    workload(job)
    require(job['captureEvidence'] is False and config['captureEvidence'] is True and config['maximumDraftTokens']==2,
        'Exact local depth2 capture policy')
    prompt_raw=inputs.read(harness/'deployment/prompts/prompt-128.json',131072);prompt=parse_json(prompt_raw)
    require(digest(prompt_raw)==job['promptFileSHA256'] and len(prompt)==128 and all(type(x) is int and 0<=x<262144 for x in prompt),
        'Exact prompt packet')
    requests=[request_hash(job,i,prompt) for i in range(4)]
    require(ordinary_scope(job,result['planSHA256'],requests)==result['ordinaryInputScopeSHA256'],'Ordinary input scope differs')
    scope=text_hash(['gemma4-local-mtp-cohort-v1',config_sha,config['benchmarkJobSHA256'],result['ordinaryInputScopeSHA256'],
        result['assistantLoad']['artifactSHA256'],result['assistantLoad']['parameterLayoutSHA256'],
        'maximumDraftTokens=2','captureEvidence=true','qualifyConditioning='+str(arm['operation']=='qualify-mtp-conditioning').lower(),
        'mtp=true','remote=false']+requests)
    require(scope==result['scopeSHA256'],'Actual MTP scope differs')
    require(config['benchmarkJobSHA256']==digest(inputs.read(case/'full.json',16384)),'Config actual job hash')
    return dict(arm=arm,job=job,result=result,config=config,requests=requests,scope=scope,returned=returned,
        source=source,comparison=comparison,physical=physical_receipt,prompt=prompt,
        resources=[rows[x] for x in ('bundle/mlx.metallib','bundle/mlx-swift-lm_MLXLMCommon.bundle/pagedattention.metal')])


def semantics(job):
    # Fresh UUIDs and distinct explicitly pinned native/deployment namespaces
    # differ. All remaining numerical workload/model/prompt fields must match.
    value=workload(job)
    return {k:v for k,v in value.items() if k not in ('buildIdentitySHA256','metadataDirectory','promptFile')}


def compare():
    inputs=Inputs();source_check(inputs);arms=[provenance(inputs,a) for a in ARMS]
    a,b=arms
    equal(semantics(a['job']),semantics(b['job']),'Matched MTP workload changed')
    equal(a['prompt'],b['prompt'],'Prompt token bytes changed')
    require(set(a['job']['requestIDs']).isdisjoint(b['job']['requestIDs']) and a['job']['membershipEpoch']!=b['job']['membershipEpoch'],
        'Fresh comparison request identities reused')
    equal(a['resources'],b['resources'],'Compiled native resource package changed')
    before={x['path']:x for x in a['source']['files']};after={x['path']:x for x in b['source']['files']}
    require(len(before)==76 and len(after)==109 and set(before)<=set(after),'Source inventory count/removal differs')
    changed=[x for x in before if before[x]!=after[x]]
    require({Path(x).name for x in changed}==CHANGED and len(changed)==5 and len(set(after)-set(before))==33,
        'Unreviewed compiled source delta')
    equal(a['result']['sourceLoad'],b['result']['sourceLoad'],'Actual target source/load/accounting changed')
    equal(a['result']['assistantLoad'],b['result']['assistantLoad'],'Actual assistant source/load/accounting changed')
    for field in ('constructorReserveBytes','liveNativeReserveBytes','liveHostReserveBytes','verificationNativeReserveBytes',
                  'logicalSnapshotBytes','completedItems','constructorUnmaterializedPackedCount','placement','policy'):
        equal(a['result']['auxiliaryResources'][field],b['result']['auxiliaryResources'][field],'Auxiliary charged term changed: '+field)
    for field in ('namedArrays','namedAllocationBounds','namedNativeReserveBytes','selectedAllocationBounds','stateLogicalBytes',
                  'persistentCastLogicalBytes','guardMetricsHostReserveBytes','hostEvidenceReserveBytes','selectedTensorCount','policy'):
        equal(a['result']['resources'][field],b['result']['resources'][field],'Original target charged term changed: '+field)
    readers=[Sidecars(inputs,x['returned'],x['result']['files']) for x in arms]
    summaries=[];state_bytes=0;rows_equal=True;states_equal=True;acceptance_equal=True
    for ordinal in range(4):
        samples=[x['result']['samples'][ordinal] for x in arms];generations=[s['generation'] for s in samples]
        evidence=[s['evidence'] for s in samples]
        for arm,s,g,e in zip(arms,samples,generations,evidence):
            require(s['requestID']==arm['job']['requestIDs'][ordinal] and s['requestStateRetired'] is True
                and g['requestSHA256']==arm['requests'][ordinal] and g['ordinal']==ordinal and g['warmup'] is (ordinal==0)
                and g['committedTokens']==143 and s['scopeSHA256']==text_hash([arm['scope'],'iteration='+str(ordinal),arm['requests'][ordinal]]),
                'Actual per-request scope/frontier differs')
            require(e['capturedBeforeRequestRetirement'] is True and e['outsideGenerationTiming'] is True,'Evidence captured after state retirement')
            binding(s['binding'],arm['result']['sourceLoad'])
        equal(samples[0]['binding'],samples[1]['binding'],'Full model/state layout binding changed')
        equal(generations[0]['selectedTokenIDs'],generations[1]['selectedTokenIDs'],'MTP token regression')
        accounting={k:generations[0][k] for k in ('verificationWidths','acceptedPrefixes','verifiedWindows','proposalTokens','acceptedProposalTokens','seedSteps')}
        equal(accounting,{k:generations[1][k] for k in accounting},'MTP accepted-prefix/work-count regression')
        actual_rows=[row(e['finalRow'],reader,ordinal,g['selectedTokenIDs'][-1]) for e,reader,g in zip(evidence,readers,generations)]
        equal(actual_rows[0][0],actual_rows[1][0],'Native row dtype regression')
        row_exact=actual_rows[0][1]==actual_rows[1][1];rows_equal &= row_exact
        actual_states=[state(e['finalState'],s['binding'],reader,ordinal) for e,s,reader in zip(evidence,samples,readers)]
        states=[]
        for key,value in actual_states[0].items():
            candidate=actual_states[1][key];equal(value[:3],candidate[:3],'State dtype/shape/range regression')
            exact=value[3]==candidate[3];states_equal &= exact;state_bytes+=len(value[3])
            states.append(dict(globalLayer=key[0],component=key[1],dtype=value[0],shape=value[1],logicalRange=value[2],
                bytes=len(value[3]),previousSHA256=digest(value[3]),candidateSHA256=digest(candidate[3]),exact=exact))
        summaries.append(dict(ordinal=ordinal,warmup=ordinal==0,tokens=generations[0]['selectedTokenIDs'],acceptance=accounting,
            row=dict(dtype=actual_rows[0][0],values=262144,nativeBytes=len(actual_rows[0][1]),
                previousSHA256=digest(actual_rows[0][1]),candidateSHA256=digest(actual_rows[1][1]),exact=row_exact),
            previousStateFingerprint=evidence[0]['finalState']['fingerprint'],candidateStateFingerprint=evidence[1]['finalState']['fingerprint'],states=states))
    for reader in readers:require(reader.used==set(reader.files),'Unused/missing state/row sidecar')
    diagnostic_path=BASE/'p128-numerical-diagnostic-1/summary.json';diagnostic=inputs.json(diagnostic_path)
    require(inputs.pins[str(diagnostic_path)]['sha256']=='cc79eb15c9c0303f1c0b3826f57e1a06c9048cd0784b0156e45c23bc024c24a3'
        and diagnostic['qualificationPassed'] is False,'Known failed ordinary comparison lost')
    inputs.recheck();passed=rows_equal and states_equal and acceptance_equal
    return dict(schema='gemma4_memo_mtp_exact_nonregression_v1',status='passed' if passed else 'failed',
        exactNumericalNonregressionPassed=passed,fullRowsCompared=4,vocabularyValuesPerRow=262144,
        stateComponentsCompared=360,stateBytesCompared=state_bytes,allGeneratedTokensCompared=64,
        exactNativeRows=rows_equal,exactNativeState=states_equal,exactAcceptanceAndWorkCounts=True,
        freshFourRequestsPerArm=True,allSidecarsRead=728,shapeDTypeFrontierAndHashesValidated=True,
        auxiliaryAndTargetReservationTotalsUnchanged=True,physical=[x['physical'] for x in arms],
        nativeSHA256=[x['arm']['native'] for x in arms],sourceSHA256=[x['arm']['source'] for x in arms],
        changedExistingSources=[dict(path=p,before=before[p],after=after[p]) for p in sorted(changed)],
        addedSourceCount=33,oldConditioningQualificationOutsideTiming=True,newConditioningQualificationRequested=False,
        samples=summaries,ordinaryReferenceNumericalQualificationPassed=False,
        knownOrdinaryComparison=dict(relativeRMSError=diagnostic['finalRow']['relativeRMSError'],maximumAbsoluteError=diagnostic['finalRow']['maximumAbsoluteError'],
            exactComparisonPassed=False,diagnosticSHA256=inputs.pins[str(diagnostic_path)]['sha256']),
        noNewOrdinaryNumericalClaim=True,allIntermediateRowsCompared=False,remoteQualification=False,performanceQualification=False,
        retainedInputPins=list(inputs.pins.values()))


if __name__=='__main__':
    p=argparse.ArgumentParser(allow_abbrev=False);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    require(a.output.is_absolute() and a.output.parent.resolve()==a.output.parent and not a.output.exists(),'Fresh canonical output required')
    value=compare()
    with a.output.open('x') as stream:json.dump(value,stream,indent=2,allow_nan=False);stream.write('\n')
    print(json.dumps({k:value[k] for k in ('status','fullRowsCompared','stateComponentsCompared','stateBytesCompared','exactNativeRows','exactNativeState')}),flush=True)
    raise SystemExit(0 if value['status']=='passed' else 1)
