"""Independent admitted v4 identities, exact encoded bytes and ACK recipes."""
import re
import struct
import uuid

FLOW='profiled_prefill_measurement_v1'
POLICIES=('serial_v1','prompt_lookahead_one_v1')


def fingerprint(a,domain,data):return a.sha(domain.encode()+b'\n'+data)


def request(a,prompt,epoch):
    a.require(type(epoch) is str and re.fullmatch('[0-9a-f]{32}',epoch),'Explicit canonical epoch required')
    uid=str(uuid.UUID(hex=epoch)).upper();simple,history=a.request_identity(uid,prompt)
    steps,_=a.frames_and_commits(prompt)
    value=dict(request=dict(profile=a.PROFILE,requestID=uid,batchSize=1,promptCount=8192,chunkSize=512,outputCount=1),
        vocabularySize=248320,promptTokenIDs=prompt,teacherTokenIDs=[],steps=steps,fingerprint=history)
    return value,simple,history


def agreement(a,epoch,policy,recorded,summary,loads):
    a.require(policy in POLICIES,'Explicit supported scheduling policy required')
    return dict(version=4,flow=FLOW,profile=a.PROFILE,profileFingerprint=summary['profileFingerprint'],
        schedulingPolicy=policy,epoch=epoch,requestID=recorded['request']['requestID'].lower(),
        requestFingerprint=summary['requestFingerprint'],recordedRequestFingerprint=summary['recordedRequestFingerprint'],
        promptCount=8192,chunkSize=512,outputCount=1,batchSize=1,frameCount=16,
        promptTokenIDsSHA256=summary['promptTokenIDsSHA256'],sourceConfigurationSHA256=a.CONFIG_SHA,
        artifactAggregateSHA256=a.ARTIFACT_SHA,storageCommitmentSHA256=loads[0]['storageCommitmentSHA256'],
        planFingerprint=loads[0]['planSHA256'],producerStageFingerprint=loads[0]['stagePlanSHA256'],
        consumerStageFingerprint=loads[1]['stagePlanSHA256'],
        producerConstructionConfigurationSHA256=loads[0]['constructionConfigurationSHA256'],
        consumerConstructionConfigurationSHA256=loads[1]['constructionConfigurationSHA256'],bf16ConversionEnabled=True,
        arithmeticEnvironmentSHA256=summary['arithmeticEnvironmentSHA256'],hiddenSize=4096,nativeDType='bfloat16',
        logitsDType='bfloat16',vocabularySize=248320,selectionPolicy='mlx_argmax_all_axes_with_finite_guard_v1')


def readiness(a,agreement_fp):
    return dict(kind='qwen_long_prefill_rank_readiness',agreementFingerprint=agreement_fp,
        domain='qwen-profiled-prefill-readiness-v1',
        readinessMaterialSHA256=a.sha(('qwen-profiled-prefill-readiness-v1|'+agreement_fp).encode()),
        elements=64,byteCount=256,encoding='sha256_hex_utf8_codepoints_int32_v1',
        exchangeCompletedBeforeClock=True,freshRequestStateCreated=False)


def encoded_object(a,text,limit):
    a.require(type(text) is str,'Encoded packet must remain its exact UTF8 string')
    raw=text.encode('utf8');a.require(0<len(raw)<=limit,'Encoded packet exceeds byte limit')
    a.check_depth(raw);value=a.context()['base'].parse_json(text)
    a.require(type(value) is dict,'Encoded packet must be an object')
    return raw,value


def boundary(a,step,summary,loads,payload_sha):
    return dict(version=2,profile=a.PROFILE,profileFingerprint=summary['profileFingerprint'],
        requestFingerprint=summary['requestFingerprint'],recordedRequestFingerprint=summary['recordedRequestFingerprint'],
        sourceConfigurationSHA256=a.CONFIG_SHA,artifactAggregateSHA256=a.ARTIFACT_SHA,
        storageCommitmentSHA256=loads[0]['storageCommitmentSHA256'],planFingerprint=loads[0]['planSHA256'],
        producerStageFingerprint=loads[0]['stagePlanSHA256'],frame=step['frame'],
        tokenIDsSHA256=a.sha(','.join(map(str,step['tokenIDs'])).encode()),payloadSHA256=a.sha_string(payload_sha),
        shape=[1,512,4096],dtype='bfloat16',byteCount=4194304)


def check_frames(a,wire,actual,recorded,summary,loads,identities,agreement_fp):
    a.require(type(actual) is list and len(actual)==2,'Two frame streams required')
    for frames in actual:a.require(type(frames) is list and len(frames)==16,'Sixteen frames per rank required')
    observed=[]
    for index,step in enumerate(recorded['steps']):
        first=actual[0][index];a.require(type(first) is dict,'Frame object required')
        raw,value=encoded_object(a,first.get('exactEnvelopeJSON'),16384)
        a.require(type(value.get('boundary')) is dict,'Missing actual boundary metadata')
        header=boundary(a,step,summary,loads,value['boundary'].get('payloadSHA256'))
        expected=dict(version=4,flow=FLOW,kind='boundary',agreementFingerprint=agreement_fp,boundary=header)
        a.exact(value,expected,'v4 boundary object')
        a.require(raw==a.canonical(expected),'Sender boundary differs from its source-constructed canonical bytes')
        fp=fingerprint(a,'qwen-profiled-prefill-boundary-envelope-v1',raw);raw_sha=a.sha(raw)
        for rank in range(2):
            wanted=dict(commit=wire.commit(identities[rank],summary['recordedRequestFingerprint'],step['frame'],rank==1),
                exactEnvelopeJSON=raw.decode(),envelopeFingerprint=fp,envelopeWireBytesSHA256=raw_sha)
            a.exact(actual[rank][index],wanted,'rank frame '+str(rank)+':'+str(index))
        ack={}
        for phase in ['ready','received','consumed']:
            material='|'.join(['qwen-stage-profiled-ack-v4',FLOW,agreement_fp,phase,fp,raw_sha])
            digits=a.sha(material.encode()).encode();ack[phase]=a.sha(b''.join(struct.pack('<i',n) for n in digits))
        observed.append(dict(sequence=index,envelopeFingerprint=fp,envelopeWireBytesSHA256=raw_sha,
            payloadSHA256=header['payloadSHA256'],expectedAcknowledgementLogicalSHA256=ack))
    return observed


def token_content(a,descriptor,summary,final):
    return dict(version=4,flow=FLOW,kind='first_selected_token',profile=a.PROFILE,
        profileFingerprint=summary['profileFingerprint'],agreementFingerprint=descriptor['fingerprint'],
        epoch=descriptor['value']['epoch'],requestFingerprint=summary['requestFingerprint'],
        recordedRequestFingerprint=summary['recordedRequestFingerprint'],
        consumerStageFingerprint=descriptor['value']['consumerStageFingerprint'],
        finalBoundaryEnvelopeFingerprint=final['envelopeFingerprint'],
        finalBoundaryWireBytesSHA256=final['envelopeWireBytesSHA256'],
        frame=dict(sequence=15,phase='prefill',tokenOffset=7680,tokenCount=512,finalPromptChunk=True),
        committedTokens=8192,vocabularySize=248320,tokenOrdinal=0,
        selectionPolicy='mlx_argmax_all_axes_with_finite_guard_v1',tokenID=summary['argmaxTokenID'],
        logitsShape=[1,248320],logitsDType='bfloat16',selectionDType='uint32',allLogitsFinite=True)


def check_token(a,executions,descriptor,summary,final):
    wanted=token_content(a,descriptor,summary,final);canonical=a.canonical(wanted)
    a.require(len(canonical)<=4096,'Token packet exceeds bound')
    fp=fingerprint(a,'qwen-profiled-prefill-first-token-packet-v1',canonical);raw_sha=a.sha(canonical)
    for rank,x in enumerate(executions):
        raw,value=encoded_object(a,x.get('exactTokenPacketJSON'),4096)
        a.exact(value,wanted,'token packet content')
        a.require(raw==canonical,'Native token packet canonical bytes differ')
        a.exact(x.get('tokenPacketFingerprint'),fp,'token domain fingerprint')
        a.exact(x.get('tokenPacketWireBytesSHA256'),raw_sha,'token raw-byte digest')
        a.exact(x.get('selectedTokenID'),summary['argmaxTokenID'],'selected token')
    material='|'.join(['qwen-profiled-prefill-post-stop-v1',FLOW,descriptor['fingerprint'],'post_stop_release',fp,raw_sha])
    digits=a.sha(material.encode()).encode()
    return dict(tokenPacketFingerprint=fp,tokenPacketWireBytesSHA256=raw_sha,
        expectedPostStopAcknowledgementLogicalSHA256=a.sha(b''.join(struct.pack('<i',n) for n in digits)))
