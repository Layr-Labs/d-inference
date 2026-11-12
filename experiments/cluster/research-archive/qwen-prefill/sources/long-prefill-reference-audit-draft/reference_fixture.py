"""No-I/O synthetic reference fixture factory shared by prospective CPU tests."""
import copy
import struct


def make_fixture(a, prompt_data):
    """Return complete synthetic ready/report dictionaries; no I/O at import.

    The passed oracle loads only its pinned old source/config metadata through
    context(). No actual or future inference output is read. State digests and
    logit values are explicitly synthetic, suitable only for CPU mutation tests.
    """
    prompt_sha=a.sha(prompt_data)
    c=a.context();prompt=a.prompt_tokens(prompt_data,prompt_sha)
    rid='00112233-4455-6677-8899-AABBCCDDEEFF';simple,history=a.request_identity(rid,prompt)
    steps,commits=a.frames_and_commits(prompt)
    entries=[]
    for geometry in c['state']:
        h=a.sha(struct.pack('<i',8192)) if geometry['component']=='kv.position_offsets' else a.sha(
            f"synthetic-not-native:{geometry['globalLayerIndex']}:{geometry['component']}".encode())
        entries.append(dict(geometry,sha256=h))
    state=dict(committedTokens=8192,entries=entries,logicalByteCount=sum(e['byteCount'] for e in entries),
               fingerprint=a.state_fingerprint(entries))
    values=[0.0]*248320;values[0]=-0.0;values[73]=18.875;values[109]=18.875
    raw=b''.join(struct.pack('<H',struct.unpack('<I',struct.pack('<f',x))[0]>>16) for x in values)
    logits=dict(shape=[1,248320],dtype='bfloat16',byteCount=len(raw),logicalBytesSHA256=a.sha(raw),values=values)
    selection=dict(requestFingerprint=simple,recordedRequestFingerprint=history,frame=steps[-1]['frame'],
        committedTokens=8192,vocabularySize=248320,outputOrdinal=0,policy='mlx_argmax_all_axes_with_finite_guard_v1',
        cpuCrosscheckPolicy='finite_maximum_lowest_vocabulary_index_v1',tokenID=73,maximumTieCount=2,maximumLogit=18.875,
        logitsShape=[1,248320],logitsDType='bfloat16',selectionDType='uint32',allLogitsFinite=True,
        nativeSelectionMatchesCapturedFullRow=True)
    recorded=dict(request=dict(profile=a.PROFILE,requestID=rid,batchSize=1,promptCount=8192,chunkSize=512,outputCount=1),
        vocabularySize=248320,promptTokenIDs=prompt,teacherTokenIDs=[],steps=steps,fingerprint=history)
    execution=dict(source=copy.deepcopy(c['source']),sourceLoad=copy.deepcopy(c['load']),request=recorded,commits=commits,
        selection=selection,finalState=state,finalLogits=logits,completedFrames=16,committedTokens=8192,
        perFrameStateCaptures=0,perFrameLogitCaptures=0,finalStateCaptures=1,finalLogitCaptures=1,nativeTokenSelections=1,
        allRequestStateRetired=True,intermediateNumericalStatesExported=False,candidateNumericalComparisonPerformed=False)
    evidence=dict(kind='qwen_registered9b_long_prefill_reference',schemaVersion=1,correctnessOnly=True,
        throughputMeasurementValid=False,interprocessTransportUsed=False,physicalTransferQualified=False,
        fullModelLoads=1,freshFullModelRequests=1,stageModelsLoaded=0,modelReleased=True,allRequestStateRetired=True,
        profile=a.PROFILE,profileFingerprint=c['profileFingerprint'],promptFileSHA256=prompt_sha,
        promptTokenIDsSHA256=a.sha(','.join(map(str,prompt)).encode()),arithmeticEnvironment=copy.deepcopy(c['environment']),
        arithmeticEnvironmentSHA256=c['environmentSHA256'],resourceAdmission=copy.deepcopy(c['resource']),execution=execution)
    evidence['fingerprint']=a.evidence_fingerprint(evidence)
    ready=dict(kind='qwen_long_prefill_reference_ready',schemaVersion=1,correctnessOnly=True,throughputMeasurementValid=False,
        verifiedModelLoaded=False,freshRequestStateCreated=False,profile=a.PROFILE,profileFingerprint=c['profileFingerprint'],
        promptFileSHA256=prompt_sha,arithmeticEnvironmentSHA256=c['environmentSHA256'],recordedRequestFingerprint=history)
    report=dict(kind='qwen_long_prefill_reference_report',schemaVersion=1,completed=True,correctnessOnly=True,
        throughputMeasurementValid=False,interprocessTransportUsed=False,physicalTransferQualified=False,
        allRequestStateRetired=True,modelReleased=True,evidence=evidence,memory=[
            dict(phase='before_full_model_load',activeMLXBytes=0,cachedMLXBytes=4,peakMLXBytesSinceProcessStart=4),
            dict(phase='full_model_released_cache_cleared',activeMLXBytes=4016,cachedMLXBytes=0,peakMLXBytesSinceProcessStart=6000000000)])
    return [ready,report]

