"""Fabricated CPU records from pinned source metadata, never native outputs."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
REFERENCE = HERE
ORIGINAL_REFERENCE = HERE.parent / 'long-prefill-reference-audit-draft'
HELPER_SHA = '2d1e064c67583cf23f930b14eb05b278570d68d83df84b67cfb64afb85eda6b7'
FACTORY_SHA = 'f05a24ad2910c1194c7d14c0364ee98e45e89139961c308706971af4ad4b05f6'


def module(name, path, pin):
    assert hashlib.sha256(path.read_bytes()).hexdigest() == pin
    spec = importlib.util.spec_from_file_location(name,path)
    value = importlib.util.module_from_spec(spec);spec.loader.exec_module(value)
    return value


def make_loads(a):
    expected = a.context()['expected']
    plan = a.context()['plan']
    source = a.context()['source']; loads=[]; summaries=[]
    manifest_sha=a.sha(b'synthetic-source-descriptor-digest-not-native')
    for rank, stage in enumerate(expected['stages']):
        active=copy.deepcopy(stage['activeTensors']);inert=copy.deepcopy(stage['inertModules'])
        for item in inert:
            item['responsibility'] = ('Replace before parameter evaluation; stage 0 exports pre-final-norm hidden'
                if item['path'].endswith('model.norm') else 'Replace before parameter evaluation; stage 0 discards lazy logits'
                if rank==0 else 'Replace before parameter evaluation; incoming residual bypasses embedding; preserve checkpoint activation dtype')
        load=dict(schemaVersion=1,stageIndex=rank,verifiedAggregateSHA256=a.ARTIFACT_SHA,
            sourceConfigurationSHA256=a.CONFIG_SHA,constructionConfigurationSHA256=plan['stages'][rank]['configurationSHA256'],
            planSHA256=plan['planSHA256'],stagePlanSHA256=plan['stages'][rank]['fingerprint'],sourceTensorManifestSHA256=manifest_sha,
            sourceParameterLayoutSHA256=source['sourceParameterLayoutSHA256'],parameterLayoutSHA256=stage['parameterLayoutSHA256'],
            activeParameterLayoutSHA256=stage['activeParameterLayoutSHA256'],activeMappingSHA256=stage['activeMappingSHA256'],
            embeddingActivationDType='bfloat16',bf16ConversionEnabled=True,sourceModelTensorBytes=source['sourceModelTensorBytes'],
            loadedTensorBytes=stage['loadedTensorBytes'],largestHostTensorBytes=stage['largestHostTensorBytes'],
            activeTensors=active,inertModules=inert,inertTensorBytes=stage['inertTensorBytes'])
        summary={k:load[k] for k in ['stageIndex','constructionConfigurationSHA256','stagePlanSHA256','activeMappingSHA256',
            'activeParameterLayoutSHA256','parameterLayoutSHA256','loadedTensorBytes','inertTensorBytes']}
        summary.update(activeTensorCount=len(active),inertTensorCount=sum(len(x['parameters']) for x in inert))
        loads.append(load);summaries.append(summary)
    storage=dict(schemaVersion=1,verifiedAggregateSHA256=a.ARTIFACT_SHA,sourceConfigurationSHA256=a.CONFIG_SHA,
        planSHA256=plan['planSHA256'],sourceTensorManifestSHA256=manifest_sha,sourceModelTensorBytes=source['sourceModelTensorBytes'],
        largestSourceTensorBytes=expected['largestSourceTensorBytes'],sourceTensorCount=927,canonicalTensorCount=927,
        bf16ConversionEnabled=True,stages=summaries)
    for load in loads:load.update(storageCommitment=copy.deepcopy(storage),storageCommitmentSHA256=a.sha(a.canonical(storage)))
    return loads


def fixture():
    a=module('pair_fixture_reference',REFERENCE/'qwen_long_prefill_reference_cut12_audit.py',HELPER_SHA)
    factory=module('pair_fixture_reference_factory',ORIGINAL_REFERENCE/'reference_fixture.py',FACTORY_SHA)
    prompt=json.dumps([i%317 for i in range(8192)],separators=(',',':')).encode()
    ref=factory.make_fixture(a,prompt)[1]['evidence'];x=ref['execution'];loads=make_loads(a)
    spec=x['request']['request'];history=x['request']['fingerprint'];simple=x['selection']['requestFingerprint']
    descriptor=dict(version=4,flow='profiled_prefill_measurement_v1',profile=a.PROFILE,profileFingerprint=ref['profileFingerprint'],
        schedulingPolicy='serial_v1',epoch='1'*32,requestID=spec['requestID'].lower(),requestFingerprint=simple,
        recordedRequestFingerprint=history,promptCount=8192,chunkSize=512,outputCount=1,batchSize=1,frameCount=16,
        promptTokenIDsSHA256=ref['promptTokenIDsSHA256'],sourceConfigurationSHA256=a.CONFIG_SHA,artifactAggregateSHA256=a.ARTIFACT_SHA,
        storageCommitmentSHA256=loads[0]['storageCommitmentSHA256'],planFingerprint=loads[0]['planSHA256'],
        producerStageFingerprint=loads[0]['stagePlanSHA256'],consumerStageFingerprint=loads[1]['stagePlanSHA256'],
        producerConstructionConfigurationSHA256=loads[0]['constructionConfigurationSHA256'],
        consumerConstructionConfigurationSHA256=loads[1]['constructionConfigurationSHA256'],bf16ConversionEnabled=True,
        arithmeticEnvironmentSHA256=ref['arithmeticEnvironmentSHA256'],hiddenSize=4096,nativeDType='bfloat16',logitsDType='bfloat16',
        vocabularySize=248320,selectionPolicy='mlx_argmax_all_axes_with_finite_guard_v1')
    agreement_fp=a.sha(b'qwen-profiled-prefill-start-agreement-v1\n'+a.canonical(descriptor))
    ids=[]
    for rank,load in enumerate(loads):
        ids.append(dict(stageIndex=rank,requestFingerprint=simple,artifactAggregateSHA256=a.ARTIFACT_SHA,
            storageCommitmentSHA256=load['storageCommitmentSHA256'],bf16ConversionEnabled=True,sourceConfigurationSHA256=a.CONFIG_SHA,
            constructionConfigurationSHA256=load['constructionConfigurationSHA256'],planFingerprint=load['planSHA256'],
            stageFingerprint=load['stagePlanSHA256'],activationDType='bfloat16'))
    frames=[]
    for step in x['request']['steps']:
        f=step['frame'];commits=[]
        for rank in range(2):
            commits.append(dict(identity=ids[rank],recordedRequestFingerprint=history,frame=f,committedTokens=step['committedTokens'],
                outputKind='hidden' if rank==0 else 'logits' if f['finalPromptChunk'] else 'evaluation_handle',
                outputShape=[1,512,4096] if rank==0 else [1,248320 if f['finalPromptChunk'] else 1],outputDType='bfloat16'))
        header=dict(version=2,profile=a.PROFILE,profileFingerprint=ref['profileFingerprint'],requestFingerprint=simple,
            recordedRequestFingerprint=history,sourceConfigurationSHA256=a.CONFIG_SHA,artifactAggregateSHA256=a.ARTIFACT_SHA,
            storageCommitmentSHA256=loads[0]['storageCommitmentSHA256'],planFingerprint=loads[0]['planSHA256'],
            producerStageFingerprint=loads[0]['stagePlanSHA256'],frame=f,tokenIDsSHA256=a.sha(','.join(map(str,step['tokenIDs'])).encode()),
            payloadSHA256=a.sha(f"synthetic-not-native-boundary:{f['sequence']}".encode()),shape=[1,512,4096],dtype='bfloat16',byteCount=4194304)
        raw=a.canonical(dict(version=4,flow='profiled_prefill_measurement_v1',kind='boundary',agreementFingerprint=agreement_fp,boundary=header))
        frames.append(dict(producer=commits[0],consumer=commits[1],boundary=header,
            envelopeFingerprint=a.sha(b'qwen-profiled-prefill-boundary-envelope-v1\n'+raw),envelopeWireBytesSHA256=a.sha(raw)))
    # Final fixture metadata is constructed separately from the audit's checker.
    final=[]
    for rank,load in enumerate(loads):
        entries=[e for e in x['finalState']['entries'] if ((0<=e['globalLayerIndex']<12) if rank==0 else (12<=e['globalLayerIndex']<32))]
        source=dict(stageIndex=rank,artifactAggregateSHA256=a.ARTIFACT_SHA,sourceConfigurationSHA256=a.CONFIG_SHA,
            sourceParameterLayoutSHA256=x['source']['sourceParameterLayoutSHA256'],sourceModelTensorBytes=x['source']['sourceModelTensorBytes'],
            loadedTensorBytes=load['loadedTensorBytes'],planSHA256=load['planSHA256'],storageCommitmentSHA256=load['storageCommitmentSHA256'],
            sourceLoadReceiptSHA256=a.sha(a.canonical(load)),arithmeticEnvironmentSHA256=ref['arithmeticEnvironmentSHA256'],
            promptFileSHA256=ref['promptFileSHA256'],promptTokenIDsSHA256=ref['promptTokenIDsSHA256'],bf16ConversionEnabled=True,embeddingActivationDType='bfloat16')
        d=dict(kind='qwen_layer_stage_profiled_prefill_final_digest',schemaVersion=1,correctnessOnly=True,throughputMeasurementValid=False,
            modelForwardCompared=False,physicalTransferQualified=False,nativeLogitBytesCompared=False,fullVocabularyValuesExported=False,
            requestStateRetirementStillRequired=True,externalPostStopOrderingStillRequired=True,profile=a.PROFILE,
            profileFingerprint=ref['profileFingerprint'],agreementFingerprint=agreement_fp,identity=ids[rank],recordedRequestFingerprint=history,
            source=source,completedFrames=16,committedTokens=8192,
            finalState=dict(committedTokens=8192,entries=entries,logicalByteCount=sum(e['byteCount'] for e in entries),fingerprint=a.state_fingerprint(entries)),
            perFrameStateCaptures=0,perFrameLogitCaptures=0,finalStateCaptures=1,finalLogitCaptures=rank,nativeTokenSelections=rank)
        if rank:d['finalLogits']=dict(kind='qwen_layer_stage_prefill_final_logits',identity=ids[1],recordedRequestFingerprint=history,
            frame=x['request']['steps'][-1]['frame'],committedTokens=8192,vocabularySize=248320,
            **{k:v for k,v in x['finalLogits'].items() if k!='values'})
        d['fingerprint']=a.sha('\n'.join(['qwen-layer-stage-profiled-prefill-final-digest-v1',agreement_fp,a.PROFILE,
            ref['profileFingerprint'],history,a.sha(a.canonical(ids[rank])),a.sha(a.canonical(source)),d['finalState']['fingerprint'],
            a.sha(a.canonical(d['finalLogits'])) if rank else 'no-logits']).encode())
        final.append(d)
    selected=dict(kind='qwen_layer_stage_prefill_local_token',identity=ids[1],recordedRequestFingerprint=history,
        frame=x['request']['steps'][-1]['frame'],committedTokens=8192,vocabularySize=248320,outputOrdinal=0,
        selectionPolicy=descriptor['selectionPolicy'],tokenID=73,logitsShape=[1,248320],logitsDType='bfloat16',selectionDType='uint32',allLogitsFinite=True)
    comparison=dict(kind='qwen_long_prefill_pair_comparison',schemaVersion=1,correctnessOnly=True,throughputMeasurementValid=False,
        interprocessTransportUsed=False,physicalTransferQualified=False,baselineEvidenceFingerprint=ref['fingerprint'],agreement=descriptor,
        agreementFingerprint=agreement_fp,frames=frames,selectedToken=selected,finalDigests=final,
        combinedFinalStateFingerprint=x['finalState']['fingerprint'],completeStateMetadataAndDigestsExact=True,
        finalLogitMetadataAndDigestExact=True,selectedTokenExact=True,allRequestStateRetired=True,candidateFullLogitValuesExported=False,
        candidateNativeBytesComparedDirectly=False,nativeBoundaryCopies=16)
    phases=['before_baseline_load','baseline_released_cache_cleared','both_stages_loaded','stage_requests_retired_weights_resident','stage_models_released_cache_cleared']
    memory=[dict(phase=p,activeMLXBytes=4,cachedMLXBytes=0,peakMLXBytesSinceProcessStart=6_000_000_000) for p in phases]
    checkpoint=dict(kind='qwen_long_prefill_pair_reference_checkpoint',schemaVersion=1,baselineModelReleasedBeforeStageLoading=True,
                    reference=ref,memory=copy.deepcopy(memory[:2]))
    report=dict(kind='qwen_long_prefill_pair_report',schemaVersion=1,correctnessOnly=True,throughputMeasurementValid=False,
        interprocessTransportUsed=False,physicalTransferQualified=False,baselineModelReleasedBeforeStageLoading=True,stageModelsReleased=True,
        allRequestStateRetired=True,stageLoads=loads,comparison=comparison,memory=memory)
    return a,prompt,[checkpoint,report]
