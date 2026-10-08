"""Validate the base metadata needed to correlate phase events.

This deliberately does not replace the separately frozen numerical/wire oracle.
Source tensors, payload digests, final states, selection and memory are opaque here.
"""
import re
import phase_contract as c

SOLO_READY='kind schemaVersion correctnessOnly throughputMeasurementValid verifiedModelLoaded freshRequestStateCreated profile profileFingerprint promptFileSHA256 arithmeticEnvironmentSHA256 recordedRequestFingerprint'
SOLO_REPORT='kind schemaVersion completed correctnessOnly throughputMeasurementValid interprocessTransportUsed physicalTransferQualified allRequestStateRetired modelReleased profile profileFingerprint promptFileSHA256 promptTokenIDsSHA256 arithmeticEnvironment arithmeticEnvironmentSHA256 resourceAdmission execution memory'
SOLO_EXECUTION='kind schemaVersion correctnessOnly throughputMeasurementValid interprocessTransportUsed physicalTransferQualified independentNumericalComparisonPerformed fullVocabularyValuesExported nativeLogitBytesCompared source sourceLoad request commits selection finalState finalLogits timing completedFrames committedTokens perFrameStateCaptures perFrameLogitCaptures finalStateCaptures finalLogitCaptures nativeTokenSelections allRequestStateRetired'
RANK_COMMON='schemaVersion epoch rank worldSize transport backend flow envelopeVersion agreementFingerprint agreement promptFileSHA256'
RANK_READY='kind modelsReadyAgreementValidated freshRequestStateCreated '+RANK_COMMON
RANK_REPORT='kind completed correctnessOnly throughputMeasurementValid modelForwardCompared physicalTransferQualified sourceLoad request arithmeticEnvironment arithmeticEnvironmentSHA256 resourceAdmission execution allRequestStateRetired modelReleased memory '+RANK_COMMON
RANK_EXECUTION='kind schemaVersion correctnessOnly throughputMeasurementValid interprocessTransportUsed physicalTransferQualified independentNumericalComparisonPerformed profile profileFingerprint agreementFingerprint identity readiness frames actions selectedTokenID exactTokenPacketJSON tokenPacketFingerprint tokenPacketWireBytesSHA256 finalDigest completedFrames committedTokens preparedAheadFrames releasedOriginalBoundaryHandles postStopReleaseCompleted allRequestStateRetired originalWrapperReleaseIsNotProofOfNoStorageAliases'
AGREEMENT='version flow profile profileFingerprint schedulingPolicy epoch requestID requestFingerprint recordedRequestFingerprint promptCount chunkSize outputCount batchSize frameCount promptTokenIDsSHA256 sourceConfigurationSHA256 artifactAggregateSHA256 storageCommitmentSHA256 planFingerprint producerStageFingerprint consumerStageFingerprint producerConstructionConfigurationSHA256 consumerConstructionConfigurationSHA256 bf16ConversionEnabled arithmeticEnvironmentSHA256 hiddenSize nativeDType logitsDType vocabularySize selectionPolicy'
FLOW='profiled_prefill_measurement_v1'


def digest(value):
    c.require(type(value) is str and re.fullmatch('[0-9a-f]{64}',value),'Invalid SHA256 metadata');return value


def logical_prompt(request):return c.sha(','.join(map(str,request['promptTokenIDs'])).encode())


def base(rows,role):
    c.require(role in ('solo','rank0','rank1'),'Explicit supported role required')
    c.require(type(rows) is list and len(rows)==2,'Ready and report required')
    ready,report=rows
    if role=='solo':return solo(ready,report)
    return rank(ready,report,int(role[-1]))


def common_report(report):
    c.flags(report,schemaVersion=1,completed=True,correctnessOnly=True,throughputMeasurementValid=False,
        physicalTransferQualified=False,allRequestStateRetired=True,modelReleased=True)
    digest(report['promptFileSHA256']);digest(report['arithmeticEnvironmentSHA256'])


def solo(ready,report):
    c.fields(ready,SOLO_READY,'solo ready');c.fields(report,SOLO_REPORT,'solo report');common_report(report)
    c.flags(report,kind='qwen_long_prefill_solo_report',interprocessTransportUsed=False,profile=c.PROFILE,profileFingerprint=c.PROFILE_FP)
    x=report['execution'];c.fields(x,SOLO_EXECUTION,'solo execution')
    c.flags(x,kind='qwen_long_prefill_solo_request',schemaVersion=1,correctnessOnly=True,throughputMeasurementValid=False,
        interprocessTransportUsed=False,physicalTransferQualified=False,independentNumericalComparisonPerformed=False,
        fullVocabularyValuesExported=False,nativeLogitBytesCompared=False,completedFrames=16,committedTokens=8192,
        perFrameStateCaptures=0,perFrameLogitCaptures=0,finalStateCaptures=1,finalLogitCaptures=1,nativeTokenSelections=1,
        allRequestStateRetired=True)
    identity=c.request(x['request'])
    c.exact(ready,dict(kind='qwen_long_prefill_solo_ready',schemaVersion=1,correctnessOnly=True,throughputMeasurementValid=False,
        verifiedModelLoaded=True,freshRequestStateCreated=False,profile=c.PROFILE,profileFingerprint=c.PROFILE_FP,
        promptFileSHA256=report['promptFileSHA256'],arithmeticEnvironmentSHA256=report['arithmeticEnvironmentSHA256'],
        recordedRequestFingerprint=identity['history']),'solo ready identity')
    c.exact(report['promptTokenIDsSHA256'],logical_prompt(x['request']),'logical prompt')
    commits=[dict(frame=step['frame'],committedTokens=step['committedTokens'],outputKind='logits' if i==15 else 'evaluation_handle',
        outputShape=[1,248320 if i==15 else 1],outputDType='bfloat16') for i,step in enumerate(identity['steps'])]
    c.exact(x['commits'],commits,'solo commits')
    return dict(role='solo',recordedRequestFingerprint=identity['history'],requestFingerprint=identity['simple'],
        profile=c.PROFILE,profileFingerprint=c.PROFILE_FP,requestID=identity['uuid'],
        promptFileSHA256=report['promptFileSHA256'],promptTokenIDsSHA256=report['promptTokenIDsSHA256'],
        expectedEvents=c.solo_events(),primaryClock=c.primary_clock(x['timing'],'solo'))


def rank(ready,report,index):
    c.fields(ready,RANK_READY,'rank ready');c.fields(report,RANK_REPORT,'rank report');common_report(report)
    c.flags(report,kind='qwen_long_prefill_rank_report',rank=index,worldSize=2,transport='loopback-test',backend='ring',
        flow=FLOW,envelopeVersion=4,modelForwardCompared=False)
    identity=c.request(report['request']);epoch=report['epoch']
    c.require(type(epoch) is str and re.fullmatch('[0-9a-f]{32}',epoch),'Canonical epoch required')
    c.exact(epoch,identity['uuid'].replace('-',''),'request epoch')
    agreement=report['agreement'];c.fields(agreement,AGREEMENT,'agreement descriptor')
    policy=agreement['schedulingPolicy'];c.require(policy in c.timeline().POLICIES,'Unknown scheduling policy')
    c.flags(agreement,version=4,flow=FLOW,profile=c.PROFILE,profileFingerprint=c.PROFILE_FP,epoch=epoch,
        requestID=identity['uuid'],requestFingerprint=identity['simple'],recordedRequestFingerprint=identity['history'],
        promptCount=8192,chunkSize=512,outputCount=1,batchSize=1,frameCount=16,
        promptTokenIDsSHA256=logical_prompt(report['request']),bf16ConversionEnabled=True,
        arithmeticEnvironmentSHA256=report['arithmeticEnvironmentSHA256'],hiddenSize=4096,nativeDType='bfloat16',
        logitsDType='bfloat16',vocabularySize=248320,selectionPolicy='mlx_argmax_all_axes_with_finite_guard_v1')
    for key,value in agreement.items():
        if key.endswith(('SHA256','Fingerprint')):digest(value)
    fp=c.sha(b'qwen-profiled-prefill-start-agreement-v1\n'+c.canonical(agreement))
    c.exact(report['agreementFingerprint'],fp,'agreement fingerprint')
    wanted={key:report[key] for key in RANK_COMMON.split()}
    wanted.update(kind='qwen_long_prefill_rank_ready',modelsReadyAgreementValidated=True,freshRequestStateCreated=False)
    c.exact(ready,wanted,'rank ready identity')
    x=report['execution'];c.fields(x,RANK_EXECUTION+(' timing' if index==0 else ' localSelection'),'rank execution')
    c.flags(x,kind='qwen_long_prefill_rank_request',schemaVersion=1,correctnessOnly=True,throughputMeasurementValid=False,
        interprocessTransportUsed=True,physicalTransferQualified=False,independentNumericalComparisonPerformed=False,
        profile=c.PROFILE,profileFingerprint=c.PROFILE_FP,agreementFingerprint=fp,completedFrames=16,committedTokens=8192,
        preparedAheadFrames=15 if index==0 and policy=='prompt_lookahead_one_v1' else 0,releasedOriginalBoundaryHandles=16,
        postStopReleaseCompleted=True,allRequestStateRetired=True,originalWrapperReleaseIsNotProofOfNoStorageAliases=True)
    actions=c.timeline().expected_actions(index,policy);c.exact(x['actions'],actions,'actual scalar actions')
    events=[]
    for action in actions:
        event=dict(ordinal=action['ordinal'],phase=action['action'],committedTokens=action['nativeCommittedTokens'])
        if 'frameSequence' in action:event['frameSequence']=action['frameSequence']
        events.append(event)
    # Native/wire/identity schemas inside frames remain the separately pinned audit's scope.
    c.require(type(x['frames']) is list and len(x['frames'])==16,'Sixteen native frame records required')
    for actual,step in zip(x['frames'],identity['steps']):
        c.fields(actual,'commit exactEnvelopeJSON envelopeFingerprint envelopeWireBytesSHA256','rank frame metadata')
        commit=actual['commit'];c.require(type(commit) is dict,'Commit metadata required')
        c.exact(commit.get('frame'),step['frame'],'rank commit frame')
        c.exact(commit.get('committedTokens'),step['committedTokens'],'rank commit frontier')
    result=dict(role='rank'+str(index),recordedRequestFingerprint=identity['history'],requestFingerprint=identity['simple'],
        profile=c.PROFILE,profileFingerprint=c.PROFILE_FP,requestID=identity['uuid'],epoch=epoch,schedulingPolicy=policy,
        agreementFingerprint=fp,promptFileSHA256=report['promptFileSHA256'],
        promptTokenIDsSHA256=agreement['promptTokenIDsSHA256'],expectedEvents=events)
    if index==0:result['primaryClock']=c.primary_clock(x['timing'],'rank0')
    return result
