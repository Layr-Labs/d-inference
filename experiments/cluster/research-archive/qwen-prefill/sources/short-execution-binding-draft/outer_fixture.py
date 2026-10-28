"""Exact extracted fabricated parent envelope fixture; no native evidence."""
import copy
import hashlib
import json
import short_parity_contract as contract
PROFILE='registered_qwen35_9b'
BATTERY="Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1)\t19%; discharging; 1:00 remaining present: true\n"
AC="Now drawing from 'AC Power'\n"
PROMPT=b'[ 1, 2, 3 ]\n';TEACHER=b'[4]\n'
TOKENS=dict(prompt=dict(sizeBytes=len(PROMPT),sha256=hashlib.sha256(PROMPT).hexdigest(),tokenIDs=[1,2,3]),
            teacher=dict(sizeBytes=len(TEACHER),sha256=hashlib.sha256(TEACHER).hexdigest(),tokenIDs=[4]))


def rows(profile=PROFILE):
    p=contract.PROFILES[profile];plan='a'*64;layout='b'*64;profile_fp='c'*64;evidence='d'*64;storage='e'*64
    uid='11111111-2222-4333-8444-555555555555'
    g=contract.fingerprint(['qwen-stage-request-v1|'+uid+'|3|2|2'])
    history=contract.fingerprint(['qwen-layer-stage-recorded-request-v1',g,'vocabulary=248320','prompt=1,2,3','teacher=4'])
    admission=contract.fingerprint(['registered-dense-short-reference-admission-v1',profile,p['configuration'],p['manifest'],p['artifact'],plan,
        history,TOKENS['prompt']['sha256'],TOKENS['teacher']['sha256'],'prompt=3|chunk=2|teacher=1|output=2|capacity=5'])
    coords=[dict(sequence=i,phase='prefill' if i<2 else 'decode',tokenOffset=[0,2,3][i],tokenCount=[2,1,1][i],finalPromptChunk=i==1) for i in range(3)]
    source=dict(artifactAggregateSHA256=p['artifact'],sourceConfigurationSHA256=p['configuration'],sourceParameterLayoutSHA256=layout,
        planSHA256=plan,bf16ConversionEnabled=True,embeddingActivationDType='bfloat16',sourceModelTensorBytes=p['sourceBytes'],layerCount=p['layers'],vocabularySize=248320)
    request=dict(request=dict(requestID=uid.upper(),promptCount=3,chunkSize=2,outputCount=2),vocabularySize=248320,
        promptTokenIDs=[1,2,3],teacherTokenIDs=[4],steps=[dict(frame=f,tokenIDs=ids) for f,ids in zip(coords,[[1,2],[3],[4]])],fingerprint=history)
    frames=[];compframes=[]
    for i,f in enumerate(coords):
        frame=dict(frame=f,committedTokens=[2,3,4][i],outputKind='evaluation_handle' if i==0 else 'logits',
            outputShape=[1,1 if i==0 else 248320],outputDType='bfloat16',state={'opaqueFakeState':True})
        comp=dict(frame=f,committedTokens=[2,3,4][i],stateMetadataAndDigestsExact=True)
        if i:frame['logits']={'opaqueFakeRow':[0]};comp.update(logits={'opaqueFakeRow':[1]},nativeLogitBytesExact=True)
        frames.append(frame);compframes.append(comp)
    baseline=dict(kind='qwen_layer_stage_recorded_baseline',correctnessOnly=True,throughputMeasurementValid=False,
        request=request,source=source,frames=frames,fingerprint=evidence,allRequestStateRetired=True)
    load=dict(schemaVersion=1,verifiedAggregateSHA256=p['artifact'],configurationSHA256=p['configuration'],parameterLayoutSHA256=layout,
        sourceModelTensorBytes=p['sourceBytes'],loadedTensorBytes=p['sourceBytes'],tensorCount=p['canonicalTensorCount'],bf16ConversionEnabled=True)
    common=dict(model=profile,profileFingerprint=profile_fp,planFingerprint=plan,recordedRequestFingerprint=history,
        promptSHA256=TOKENS['prompt']['sha256'],teacherSHA256=TOKENS['teacher']['sha256'],maximumTokens=5,resourceAdmissionPerformed=False,forwardExecuted=False)
    fullbudget=dict(common,role='fullReference',admissionFingerprint=admission)
    pairbudget=dict(common,role='sequentialStagePair',referenceAdmissionFingerprint=admission)
    first={k:True for k in contract.BASE_TRUE};first.update({k:False for k in contract.BASE_FALSE})
    first.update(contract.GEOMETRY,kind='qwen_dense_short_baseline_checkpoint',schemaVersion=1,model=profile,
        referenceAdmissionFingerprint=admission,promptSHA256=TOKENS['prompt']['sha256'],teacherSHA256=TOKENS['teacher']['sha256'],
        baseline=baseline,load=load,budget=fullbudget,initialResources={},releasedResources={},resourceObservations=[],memory=[],runtime={},fullModelsLoaded=1,fullCheckpointVerificationPasses=1)
    loads=[dict(schemaVersion=1,stageIndex=i,verifiedAggregateSHA256=p['artifact'],sourceConfigurationSHA256=p['configuration'],
        planSHA256=plan,sourceParameterLayoutSHA256=layout,sourceModelTensorBytes=p['sourceBytes'],bf16ConversionEnabled=True,
        embeddingActivationDType='bfloat16',storageCommitmentSHA256=storage) for i in range(2)]
    comparison=dict(kind='qwen_layer_stage_recorded_comparison',correctnessOnly=True,throughputMeasurementValid=False,sequentialOneProcessOnly=True,
        nativeBoundaryBytesCopied=True,baselineEvidenceSHA256=evidence,requestSHA256=history,source=copy.deepcopy(source),stageStorageCommitmentSHA256=storage,frames=compframes,allRequestStateRetired=True)
    pair={k:True for k in contract.PAIR_TRUE};pair.update(comparison=comparison,stageLoads=loads,budget=pairbudget,
        initialResources={},releasedResources={},resourceObservations=[],memory=[],runtime={},stageModelsLoaded=2,fullCheckpointVerificationPasses=1,physicalBufferLineageAttested=False)
    last={k:True for k in contract.FINAL_TRUE};last.update({k:False for k in contract.FINAL_FALSE})
    last.update(contract.GEOMETRY,kind='qwen_dense_short_parity_report',schemaVersion=1,model=profile,
        referenceAdmissionFingerprint=admission,recordedRequestFingerprint=history,promptSHA256=TOKENS['prompt']['sha256'],teacherSHA256=TOKENS['teacher']['sha256'],baselineEvidenceSHA256=evidence,pair=pair)
    return [first,last]

def raw(values):return b''.join(json.dumps(v,separators=(',',':')).encode()+b'\n' for v in values)
