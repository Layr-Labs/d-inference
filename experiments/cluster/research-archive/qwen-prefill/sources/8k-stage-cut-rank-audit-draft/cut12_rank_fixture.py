"""Fabricated CPU fixtures. No new native candidate, input or model reads.

The frozen pair fixture supplies independently constructed metadata, state
digest placeholders and synthetic reference values. Rank traces and outer
records are assembled here separately from the rank oracle's builders.
"""
import copy
import json
import uuid

import cut12_rank_dependencies as dep

PAIR_FIXTURE_SHA='96a8e64036ca3e02ca5be6044764d8597404527049f9c90b971e0df9f7d41c8e'
EPOCH='abcdef0123456789abcdef0123456789'


def remap(value, mapping):
    if type(value) is str:return mapping.get(value,value)
    if type(value) is dict:return {k:remap(v,mapping) for k,v in value.items()}
    if type(value) is list:return [remap(v,mapping) for v in value]
    return value


def actions(rank,policy):
    rows=[]
    def add(name,tokens,completed,prepared=0,pending=0,frame=None):
        row=dict(ordinal=len(rows),action=name,nativeCommittedTokens=tokens,completedBoundaryCount=completed,
            explicitPreparedBoundarySlots=prepared,pendingConsumedFrameSlots=pending)
        if frame is not None:row['frameSequence']=frame
        rows.append(row)
    for name in ('readiness.begin','readiness.completed'):add(name,0,0)
    for phase in (('beginStartSend','startSendCompleted') if rank==0 else ('beginStartReceive','startValidated')):
        add('control.'+phase,0,0)
    add('freshContextCreated',0,0)
    for i in range(16):
        n=(i+1)*512
        if rank==0:
            if i==0 or policy=='serial_v1':
                add('prepare.begin',i*512,i,frame=i);add('prepare.committed',n,i,1,frame=i)
            for phase in ('beginHeader','headerSendCompleted','readyACKAccepted','beginPayloadSend','payloadSendCompleted'):
                add('send.'+phase,n,i,1,frame=i)
            add('send.receivedACKAccepted',n,i,1,1,i);add('producerBoundaryReleased',n,i,0,1,i)
            ahead=policy=='prompt_lookahead_one_v1' and i<15
            if ahead:
                add('prepare.begin',n,i,0,1,i+1);add('prepare.committed',n+512,i,1,1,i+1)
            committed=n+512 if ahead else n;prepared=int(ahead)
            add('send.beginConsumedDrain',committed,i,prepared,1,i)
            add('send.consumedACKAccepted',committed,i+1,prepared,0,i)
            add('frameCompleted',committed,i+1,prepared,0,i)
        else:
            for phase in ('beginHeaderReceive','headerValidated','beginReadyACK','readyACKSendCompleted','beginPayloadReceive',
                'payloadReceivedAndValidated','beginReceivedACK','receivedACKSendCompleted','beginConsumption'):
                add('receive.'+phase,i*512,i,frame=i)
            for phase in ('consumptionAndSelectionValidated','consumedBoundaryReleased','beginConsumedACK'):
                add('receive.'+phase,n,i,frame=i)
            add('receive.consumedACKSendCompleted',n,i+1,frame=i);add('frameCompleted',n,i+1,frame=i)
    ending=('control.beginTokenReceive','control.tokenValidated','firstTokenStopRecorded','control.beginPostStopSend',
        'control.postStopSendCompleted','postStopDiagnostics.begin','requestClosed') if rank==0 else (
        'control.beginTokenSend','control.tokenSendCompleted','control.beginPostStopReceive','control.postStopValidated',
        'postStopDiagnostics.begin','requestClosed')
    for name in ending:add(name,8192,16)
    return rows


def fixture(policy='serial_v1', epoch=EPOCH):
    a=dep.context()[0]
    pf=dep.load_module('rank_fixture_frozen_pair',dep.ROOT/'8k-stage-cut-pair-audit-draft/cut12_pair_fixture.py',PAIR_FIXTURE_SHA)
    _,prompt,pair=pf.fixture()
    reference=pair[0]['reference'];baseline_request=reference['execution']['request'];comparison=pair[1]['comparison']
    old_simple=reference['execution']['selection']['requestFingerprint'];old_history=baseline_request['fingerprint']
    new_id=str(uuid.UUID(hex=epoch)).upper();simple,history=a.request_identity(new_id,baseline_request['promptTokenIDs'])
    mapping={old_simple:simple,old_history:history,baseline_request['request']['requestID']:new_id}
    value=remap(comparison,mapping);loads=pair[1]['stageLoads']
    descriptor=value['agreement'];descriptor.update(epoch=epoch,requestID=new_id.lower(),schedulingPolicy=policy)
    agreement_fp=a.sha(b'qwen-profiled-prefill-start-agreement-v1\n'+a.canonical(descriptor))
    value=remap(value,{value['agreementFingerprint']:agreement_fp});descriptor=value['agreement']
    request=remap(baseline_request,mapping)
    frames=[[],[]]
    for item in value['frames']:
        raw=a.canonical(dict(version=4,flow='profiled_prefill_measurement_v1',kind='boundary',
            agreementFingerprint=agreement_fp,boundary=item['boundary']))
        for rank,role in enumerate(('producer','consumer')):
            frames[rank].append(dict(commit=item[role],exactEnvelopeJSON=raw.decode(),
                envelopeFingerprint=a.sha(b'qwen-profiled-prefill-boundary-envelope-v1\n'+raw),envelopeWireBytesSHA256=a.sha(raw)))
    final=[]
    for d in value['finalDigests']:
        d['fingerprint']=a.sha('\n'.join(['qwen-layer-stage-profiled-prefill-final-digest-v1',agreement_fp,a.PROFILE,
            d['profileFingerprint'],history,a.sha(a.canonical(d['identity'])),a.sha(a.canonical(d['source'])),
            d['finalState']['fingerprint'],a.sha(a.canonical(d['finalLogits'])) if 'finalLogits' in d else 'no-logits']).encode())
        final.append(d)
    selected=value['selectedToken'];last=frames[0][-1]
    packet=dict(version=4,flow='profiled_prefill_measurement_v1',kind='first_selected_token',profile=a.PROFILE,
        profileFingerprint=reference['profileFingerprint'],agreementFingerprint=agreement_fp,epoch=epoch,
        requestFingerprint=simple,recordedRequestFingerprint=history,consumerStageFingerprint=descriptor['consumerStageFingerprint'],
        finalBoundaryEnvelopeFingerprint=last['envelopeFingerprint'],finalBoundaryWireBytesSHA256=last['envelopeWireBytesSHA256'],
        frame=request['steps'][-1]['frame'],committedTokens=8192,vocabularySize=248320,tokenOrdinal=0,
        selectionPolicy='mlx_argmax_all_axes_with_finite_guard_v1',tokenID=selected['tokenID'],logitsShape=[1,248320],
        logitsDType='bfloat16',selectionDType='uint32',allLogitsFinite=True)
    token_raw=a.canonical(packet)
    readiness=dict(kind='qwen_long_prefill_rank_readiness',agreementFingerprint=agreement_fp,
        domain='qwen-profiled-prefill-readiness-v1',readinessMaterialSHA256=a.sha(('qwen-profiled-prefill-readiness-v1|'+agreement_fp).encode()),
        elements=64,byteCount=256,encoding='sha256_hex_utf8_codepoints_int32_v1',exchangeCompletedBeforeClock=True,freshRequestStateCreated=False)
    timing=dict(clock='DispatchTime.uptimeNanoseconds_rank_zero_only',startEvent='before_start_send_and_fresh_context_creation',
        stopEvent='after_final_consumed_and_selected_token_validation',diagnosticOnly=True,startUptimeNanoseconds=10_000_000_000,
        stopUptimeNanoseconds=12_000_000_000,elapsedNanoseconds=2_000_000_000,promptTokensPerFirstTokenSecond=4096.0,
        postStopThroughRequestCloseNanoseconds=50_000_000,includesModelLoading=False,includesPreparedTokenDistribution=False,
        includesReadinessExchange=False,includesFreshRequestState=True,includesFreshContextAdmission=True,
        includesBoundaryValidationAndCopies=True,includesScalarTraceRecording=True,includesFinalTokenSelectionAndReturn=True,
        includesFinalDiagnosticCaptures=False,includesPostStopAcknowledgement=False,includesRequestRetirement=False)
    ranks=[]
    for rank in range(2):
        execution=dict(kind='qwen_long_prefill_rank_request',schemaVersion=1,correctnessOnly=True,throughputMeasurementValid=False,
            interprocessTransportUsed=True,physicalTransferQualified=False,independentNumericalComparisonPerformed=False,
            profile=a.PROFILE,profileFingerprint=reference['profileFingerprint'],agreementFingerprint=agreement_fp,
            identity=final[rank]['identity'],readiness=copy.deepcopy(readiness),frames=frames[rank],actions=actions(rank,policy),
            selectedTokenID=selected['tokenID'],exactTokenPacketJSON=token_raw.decode(),
            tokenPacketFingerprint=a.sha(b'qwen-profiled-prefill-first-token-packet-v1\n'+token_raw),tokenPacketWireBytesSHA256=a.sha(token_raw),
            finalDigest=final[rank],completedFrames=16,committedTokens=8192,
            preparedAheadFrames=15 if rank==0 and policy=='prompt_lookahead_one_v1' else 0,releasedOriginalBoundaryHandles=16,
            postStopReleaseCompleted=True,allRequestStateRetired=True,originalWrapperReleaseIsNotProofOfNoStorageAliases=True)
        if rank==0:execution['timing']=timing
        else:execution['localSelection']=selected
        common=dict(schemaVersion=1,epoch=epoch,rank=rank,worldSize=2,transport='loopback-test',backend='ring',
            flow='profiled_prefill_measurement_v1',envelopeVersion=4,agreementFingerprint=agreement_fp,
            agreement=copy.deepcopy(descriptor),promptFileSHA256=reference['promptFileSHA256'])
        ready=dict(common,kind='qwen_long_prefill_rank_ready',modelsReadyAgreementValidated=True,freshRequestStateCreated=False)
        phases=['before_stage_load','stage_loaded_no_request_state','stage_request_retired_weights_resident','stage_model_released_cache_cleared']
        memory=[dict(phase=p,activeMLXBytes=1024,cachedMLXBytes=0,peakMLXBytesSinceProcessStart=4_000_000_000) for p in phases]
        report=dict(common,kind='qwen_long_prefill_rank_report',completed=True,correctnessOnly=True,throughputMeasurementValid=False,
            modelForwardCompared=False,physicalTransferQualified=False,sourceLoad=loads[rank],request=copy.deepcopy(request),
            arithmeticEnvironment=reference['arithmeticEnvironment'],arithmeticEnvironmentSHA256=reference['arithmeticEnvironmentSHA256'],
            resourceAdmission=reference['resourceAdmission'],execution=execution,allRequestStateRetired=True,modelReleased=True,memory=memory)
        ranks.append([ready,report])
    return dict(ranks=ranks,baseline=pair,prompt=prompt,promptSHA=a.sha(prompt),epoch=epoch,policy=policy)


def encoded(rows):
    return b''.join(json.dumps(row,sort_keys=True,separators=(',',':'),allow_nan=False).encode()+b'\n' for row in rows)
