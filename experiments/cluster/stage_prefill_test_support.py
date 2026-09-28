"""Small invented metadata and CPU values; no artifact or model payload fixture."""
import copy
import math
from runtime.stage_checks.common import canonical,digest
from runtime.stage_checks import prefill,request

EPOCH='a'*32


def context(policy='serial_v1',dtype='bfloat16'):
    text=dict(num_hidden_layers=4,full_attention_interval=2,hidden_size=8,num_key_value_heads=1,head_dim=2,
        linear_num_key_heads=1,linear_key_head_dim=2,linear_num_value_heads=1,linear_value_head_dim=2,linear_conv_kernel_dim=2)
    recorded,fingerprint=request.make_request(EPOCH,[i%8 for i in range(65)],[],32,8)
    source=dict(artifactAggregateSHA256='b'*64,sourceConfigurationSHA256='c'*64,sourceParameterLayoutSHA256='d'*64,
        planSHA256='e'*64,bf16ConversionEnabled=True,embeddingActivationDType=dtype,sourceModelTensorBytes=2048,
        layerCount=4,vocabularySize=8)
    return dict(mode='prefill-ranks',artifact=source['artifactAggregateSHA256'],configuration_sha256=source['sourceConfigurationSHA256'],
        model='/model-not-opened',text=text,vocabulary=8,request=recorded,request_fingerprint=fingerprint,
        stage_prefill_policy=policy,stage_logits_dtype=dtype,baseline_admission=dict(source=source,native_dtype=dtype,
        logits_dtype=dtype,evidence_sha256='f'*64))


def baseline(ctx):
    old,_=request.make_request('9'*32,ctx['request']['promptTokenIDs'],[],32,8)
    dtype=ctx['stage_logits_dtype'];frames=[];frame_hashes=[]
    for step in old['steps']:
        frame=step['frame'];tokens=frame['tokenOffset']+frame['tokenCount'];final=frame['finalPromptChunk']
        entries=[]
        for layer in range(4):
            specs=[('conv',[1,1,6],dtype),('ssm',[1,1,2,2],'float32')] if layer%2==0 else [
                ('kv.keys',[1,1,tokens,2],dtype),('kv.position_offsets',[1],'int32'),('kv.values',[1,1,tokens,2],dtype)]
            for component,shape,entry_dtype in specs:
                size=math.prod(shape)*({'bfloat16':2,'float16':2,'float32':4,'int32':4}[entry_dtype])
                entries.append(dict(globalLayerIndex=layer,component=component,shape=shape,dtype=entry_dtype,
                                    byteCount=size,sha256=digest(bytes(size))))
        state_hash=digest('\n'.join(['cbv2-owned-state-v1',f'tokens={tokens}']+[
            f"{e['globalLayerIndex']}|{e['component']}|{e['shape']}|{e['dtype']}|{e['byteCount']}|{e['sha256']}" for e in entries]).encode())
        state=dict(committedTokens=tokens,entries=entries,logicalByteCount=sum(e['byteCount'] for e in entries),fingerprint=state_hash)
        shape=[1,8 if final else 1];kind='logits' if final else 'evaluation_handle'
        value=dict(frame=frame,committedTokens=tokens,outputKind=kind,outputShape=shape,outputDType=dtype,state=state)
        logit_hash='no-logits'
        if final:
            size=8*(4 if dtype=='float32' else 2);logit_hash=digest(bytes(size))
            value['logits']=dict(shape=[1,8],dtype=dtype,byteCount=size,logicalBytesSHA256=logit_hash,values=[0]*8)
        coordinate=f"{frame['sequence']}|prefill|{frame['tokenOffset']}|{frame['tokenCount']}|{str(final).lower()}"
        frame_hashes.append(digest('\n'.join(['qwen-recorded-frame-v1',coordinate,f'tokens={tokens}',
            f'{kind}|{shape}|{dtype}',state_hash,logit_hash]).encode()))
        frames.append(value)
    source=copy.deepcopy(ctx['baseline_admission']['source'])
    fingerprint=digest('\n'.join(['qwen-layer-stage-baseline-v1',old['fingerprint'],digest(canonical(source))]+frame_hashes).encode())
    value=dict(kind='qwen_layer_stage_recorded_baseline',correctnessOnly=True,throughputMeasurementValid=False,
        request=old,source=source,frames=frames,fingerprint=fingerprint,allRequestStateRetired=True)
    row=dict(kind='qwen_layer_stage_baseline_checkpoint',baselineModelReleasedBeforeStageLoading=True,baseline=value)
    raw=canonical(row)+b'\n';ctx['baseline_sha256']=digest(raw)
    return row,raw,fingerprint


def rows(rank,ctx):
    baseline=ctx['baseline_admission'];recorded=ctx['request'];source=baseline['source']
    descriptor=dict(version=3,flow=prefill.FLOW,schedulingPolicy=ctx['stage_prefill_policy'],epoch=EPOCH,
        requestID=recorded['request']['requestID'],requestFingerprint=ctx['request_fingerprint'],
        recordedRequestFingerprint=recorded['fingerprint'],promptCount=65,chunkSize=32,outputCount=1,
        batchSize=1,frameCount=3,vocabularySize=8,hiddenSize=8,
        promptTokenIDsSHA256=digest(','.join(map(str,recorded['promptTokenIDs'])).encode()),
        sourceConfigurationSHA256=ctx['configuration_sha256'],artifactAggregateSHA256=ctx['artifact'],
        bf16ConversionEnabled=True,nativeDType=baseline['native_dtype'],logitsDType=ctx['stage_logits_dtype'],
        selectionPolicy='mlx_argmax_all_axes_with_finite_guard_v1',
        storageCommitmentSHA256='1'*64,planFingerprint=source['planSHA256'],
        producerStageFingerprint='2'*64,consumerStageFingerprint='3'*64,
        producerConstructionConfigurationSHA256='4'*64,consumerConstructionConfigurationSHA256='5'*64)
    fingerprint=digest(b'qwen-prefill-start-agreement-v1\n'+canonical(descriptor))
    ready=dict(kind=prefill.READY,schemaVersion=1,epoch=EPOCH,rank=rank,worldSize=2,transport='loopback-test',backend='ring',
        flow=prefill.FLOW,envelopeVersion=3,modelsReadyAgreementValidated=True,freshRequestStateCreated=False,
        agreementFingerprint=fingerprint,agreement=descriptor)
    load=dict(schemaVersion=1,stageIndex=rank,verifiedAggregateSHA256=ctx['artifact'],sourceConfigurationSHA256=ctx['configuration_sha256'],
        planSHA256=source['planSHA256'],sourceParameterLayoutSHA256=source['sourceParameterLayoutSHA256'],bf16ConversionEnabled=True,
        sourceModelTensorBytes=2048,embeddingActivationDType=baseline['native_dtype'],storageCommitmentSHA256='1'*64,
        stagePlanSHA256=('2' if rank==0 else '3')*64,constructionConfigurationSHA256=('4' if rank==0 else '5')*64)
    terminal=dict(ready,kind=prefill.TERMINAL,completed=True,correctnessOnly=True,throughputMeasurementValid=False,
        modelForwardCompared=False,physicalTransferQualified=False,allRequestStateRetired=True,modelReleased=True,
        conservativeStateAndBoundaryBytes=4096,request=copy.deepcopy(recorded),sourceLoad=load,
        execution={'explicitly_opaque_test_evidence':True})
    return [ready,terminal]
