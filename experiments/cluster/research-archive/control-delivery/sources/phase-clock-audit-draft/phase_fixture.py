"""Fabricated phase metadata fixtures; deliberately NOT numerical qualification.

No native data, model files, completed-run outputs or natural prompt are read.
The production-clock string below exercises parsing only; times are synthetic.
"""
import uuid
import phase_contract as c
import phase_base as b

EPOCH='00112233445566778899aabbccddeeff'


def blank(keys):return {key:{} for key in keys.split()}


def recorded(epoch=EPOCH):
    tokens=[i%317 for i in range(8192)];uid=str(uuid.UUID(hex=epoch))
    simple=c.sha('\n'.join(['qwen-stage-profiled-prefill-request-v1',c.PROFILE,c.PROFILE_FP,uid,'batch=1','prompt=8192','chunk=512','output=1']).encode())
    history=c.sha('\n'.join(['qwen-layer-stage-profiled-prefill-recorded-request-v1',c.PROFILE,c.PROFILE_FP,simple,
        'vocabulary=248320','prompt='+','.join(map(str,tokens)),'teacher=']).encode())
    steps=[]
    for i in range(16):
        frame=dict(sequence=i,phase='prefill',tokenOffset=i*512,tokenCount=512,finalPromptChunk=i==15)
        steps.append(dict(frame=frame,tokenIDs=tokens[i*512:(i+1)*512],committedTokens=(i+1)*512))
    value=dict(request=dict(profile=c.PROFILE,requestID=uid.upper(),batchSize=1,promptCount=8192,chunkSize=512,outputCount=1),
        vocabularySize=248320,promptTokenIDs=tokens,teacherTokenIDs=[],steps=steps,fingerprint=history)
    return value,simple,history


def trace(events,role,history,origin):
    events=[dict(e,localUptimeNanoseconds=origin+e['ordinal']*1000) for e in events]
    return dict(kind='qwen_prefill_local_phase_trace',schemaVersion=1,
        identity=dict(requestFingerprint=history,profile=c.PROFILE,role=role),clockSource='DispatchTime.uptimeNanoseconds',
        maximumEvents=512,events=events,firstLocalUptimeNanoseconds=events[0]['localUptimeNanoseconds'],
        lastLocalUptimeNanoseconds=events[-1]['localUptimeNanoseconds'],traceSpanNanoseconds=(len(events)-1)*1000,
        diagnosticOnly=True,includesRecorderOverhead=True,crossProcessClockAlignmentAsserted=False,gpuOverlapAsserted=False,
        modelReleaseAsserted=False,recorderIndependentlyVerifiesRequestRetirement=False)


def timing(t,role):
    e={v['phase']:v['localUptimeNanoseconds'] for v in t['events']}
    if role=='solo':
        start=(e['freshRequest.begin']+e['freshRequest.created'])//2
        stop=(e['selection.begin']+e['selection.completed'])//2
        closed=(e['retirement.begin']+e['request.closed'])//2
        flags=dict(includesFreshRequestState=True,includesFiniteArgmaxAndScalarReadback=True,includesBoundedCommitMetadata=True,
            includesTransport=False,excludesLoadReadinessFinalCaptureAndRetirement=True)
    else:
        start=(e['readiness.completed']+e['control.beginStartSend'])//2
        stop=(e['control.tokenValidated']+e['firstTokenStopRecorded'])//2
        closed=e['requestClosed']+500;flags=c.timeline().timing_flags()
    return dict(flags,startUptimeNanoseconds=start,stopUptimeNanoseconds=stop,elapsedNanoseconds=stop-start,
        promptTokensPerFirstTokenSecond=8192e9/float(stop-start),postStopThroughRequestCloseNanoseconds=closed-stop)


def solo(origin=10**9,epoch=EPOCH):
    r,simple,history=recorded(epoch);t=trace(c.solo_events(),'solo',history,origin)
    x=blank(b.SOLO_EXECUTION);x.update(kind='qwen_long_prefill_solo_request',schemaVersion=1,correctnessOnly=True,
        throughputMeasurementValid=False,interprocessTransportUsed=False,physicalTransferQualified=False,
        independentNumericalComparisonPerformed=False,fullVocabularyValuesExported=False,nativeLogitBytesCompared=False,
        request=r,commits=[dict(frame=v['frame'],committedTokens=v['committedTokens'],outputKind='logits' if i==15 else 'evaluation_handle',
            outputShape=[1,248320 if i==15 else 1],outputDType='bfloat16') for i,v in enumerate(r['steps'])],
        timing=timing(t,'solo'),completedFrames=16,committedTokens=8192,perFrameStateCaptures=0,perFrameLogitCaptures=0,
        finalStateCaptures=1,finalLogitCaptures=1,nativeTokenSelections=1,allRequestStateRetired=True)
    report=blank(b.SOLO_REPORT);report.update(kind='qwen_long_prefill_solo_report',schemaVersion=1,completed=True,correctnessOnly=True,
        throughputMeasurementValid=False,interprocessTransportUsed=False,physicalTransferQualified=False,allRequestStateRetired=True,
        modelReleased=True,profile=c.PROFILE,profileFingerprint=c.PROFILE_FP,promptFileSHA256='a'*64,
        promptTokenIDsSHA256=b.logical_prompt(r),arithmeticEnvironmentSHA256='b'*64,execution=x)
    ready=dict(kind='qwen_long_prefill_solo_ready',schemaVersion=1,correctnessOnly=True,throughputMeasurementValid=False,
        verifiedModelLoaded=True,freshRequestStateCreated=False,profile=c.PROFILE,profileFingerprint=c.PROFILE_FP,
        promptFileSHA256='a'*64,arithmeticEnvironmentSHA256='b'*64,recordedRequestFingerprint=history)
    return [ready,report],t


def rank(index,policy='serial_v1',origin=10**9,epoch=EPOCH):
    r,simple,history=recorded(epoch)
    agreement={k:'c'*64 for k in b.AGREEMENT.split()}
    agreement.update(version=4,flow=b.FLOW,profile=c.PROFILE,profileFingerprint=c.PROFILE_FP,schedulingPolicy=policy,epoch=epoch,
        requestID=str(uuid.UUID(hex=epoch)),requestFingerprint=simple,recordedRequestFingerprint=history,promptCount=8192,
        chunkSize=512,outputCount=1,batchSize=1,frameCount=16,promptTokenIDsSHA256=b.logical_prompt(r),bf16ConversionEnabled=True,
        arithmeticEnvironmentSHA256='b'*64,hiddenSize=4096,nativeDType='bfloat16',logitsDType='bfloat16',vocabularySize=248320,
        selectionPolicy='mlx_argmax_all_axes_with_finite_guard_v1')
    fp=c.sha(b'qwen-profiled-prefill-start-agreement-v1\n'+c.canonical(agreement))
    common=dict(schemaVersion=1,epoch=epoch,rank=index,worldSize=2,transport='loopback-test',backend='ring',flow=b.FLOW,
        envelopeVersion=4,agreementFingerprint=fp,agreement=agreement,promptFileSHA256='a'*64)
    actions=c.timeline().expected_actions(index,policy);events=[]
    for a in actions:
        e=dict(ordinal=a['ordinal'],phase=a['action'],committedTokens=a['nativeCommittedTokens'])
        if 'frameSequence' in a:e['frameSequence']=a['frameSequence']
        events.append(e)
    t=trace(events,'rank'+str(index),history,origin)
    x=blank(b.RANK_EXECUTION+(' timing' if index==0 else ' localSelection'))
    x.update(kind='qwen_long_prefill_rank_request',schemaVersion=1,correctnessOnly=True,throughputMeasurementValid=False,
        interprocessTransportUsed=True,physicalTransferQualified=False,independentNumericalComparisonPerformed=False,
        profile=c.PROFILE,profileFingerprint=c.PROFILE_FP,agreementFingerprint=fp,actions=actions,
        frames=[dict(commit=dict(frame=s['frame'],committedTokens=s['committedTokens']),exactEnvelopeJSON='opaque fixture',
            envelopeFingerprint='c'*64,envelopeWireBytesSHA256='d'*64) for s in r['steps']],
        completedFrames=16,committedTokens=8192,preparedAheadFrames=15 if index==0 and policy!='serial_v1' else 0,
        releasedOriginalBoundaryHandles=16,postStopReleaseCompleted=True,allRequestStateRetired=True,
        originalWrapperReleaseIsNotProofOfNoStorageAliases=True)
    if index==0:x['timing']=timing(t,'rank0')
    report=blank(b.RANK_REPORT);report.update(common,kind='qwen_long_prefill_rank_report',completed=True,correctnessOnly=True,
        throughputMeasurementValid=False,modelForwardCompared=False,physicalTransferQualified=False,request=r,
        arithmeticEnvironmentSHA256='b'*64,execution=x,allRequestStateRetired=True,modelReleased=True)
    ready=dict(common,kind='qwen_long_prefill_rank_ready',modelsReadyAgreementValidated=True,freshRequestStateCreated=False)
    return [ready,report],t
