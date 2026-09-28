"""Invented short-rank CPU metadata, not a Qwen checkpoint or native result."""
import copy
import math
from runtime.stage_checks.common import canonical, digest
from runtime.stage_checks.request import make_request

EPOCH='a'*32
WIDTH={'bfloat16':2,'float32':4,'int32':4}


def context(layers=32,cut=None):
    text=dict(model_type='qwen3_5_text',num_hidden_layers=layers,full_attention_interval=4,
        hidden_size=8,vocab_size=16,num_key_value_heads=1,head_dim=2,linear_num_key_heads=1,
        linear_key_head_dim=32,linear_num_value_heads=1,linear_value_head_dim=4,
        linear_conv_kernel_dim=3,max_position_embeddings=1024)
    request,fingerprint=make_request(EPOCH,[1,2,3,4,5]*13,[6,7,8],32,16)
    value=dict(mode='ranks',model='/not-opened',artifact='b'*64,configuration=text,text=text,
        configuration_sha256=digest(canonical(text)),vocabulary=16,request=request,request_fingerprint=fingerprint)
    if cut is not None:value['stage_cut']=cut
    return value


def bounds(ctx):
    count=ctx['text']['num_hidden_layers'];cut=ctx.get('stage_cut',count//2)
    return [(0,cut),(cut,count)]


def layout(entries,name='localName',dtype='loadedDType'):
    return digest('\n'.join(sorted(f"{t[name]}:{t[dtype]}:{t['shape']}" for t in entries)).encode())


def loads(ctx):
    # Minimal INVENTED inventory for the existing parent consistency checker.
    # This fixture does not impersonate native mandatory tensor completeness.
    text=ctx['text'];h=text['hidden_size'];v=text['vocab_size'];spans=bounds(ctx)
    active=[[] for _ in spans]
    for rank,(start,end) in enumerate(spans):
        for layer in range(start,end):
            active[rank].append(dict(sourceName=f'model.layers.{layer}.input_layernorm.weight',
                localName=f'model.layers.{layer-start}.input_layernorm.weight',shape=[h],
                sourceDType='bfloat16',loadedDType='bfloat16',byteCount=2*h))
        roots=[('model.embed_tokens.weight',[v,h])] if rank==0 else [('lm_head.weight',[v,h]),('model.norm.weight',[h])]
        for name,shape in roots:
            active[rank].append(dict(sourceName=name,localName=name,shape=shape,
                sourceDType='bfloat16',loadedDType='bfloat16',byteCount=2*math.prod(shape)))
        active[rank].sort(key=lambda t:t['localName'])
    union=[dict(t,localName=t['sourceName']) for group in active for t in group]
    # These labeled synthetic hash tokens are never used as real Plan hashes.
    common=dict(schemaVersion=1,verifiedAggregateSHA256=ctx['artifact'],sourceConfigurationSHA256=ctx['configuration_sha256'],
        planSHA256=digest(('invented-plan-'+str(spans)).encode()),sourceTensorManifestSHA256='c'*64,
        sourceModelTensorBytes=sum(t['byteCount'] for t in union),bf16ConversionEnabled=True,
        canonicalTensorCount=len(union),sourceTensorCount=len(union),largestSourceTensorBytes=2*v*h)
    result=[];summaries=[]
    for rank,group in enumerate(active):
        roots=[('model.norm',[h],'parameter-only-replacement'),('lm_head',[1,h],'module-replacement')] if rank==0 else [('model.embed_tokens',[1,h],'module-replacement')]
        inert=[dict(path=name,replacementKind=kind,parameters=[dict(localName=name+'.weight',shape=shape,dtype='bfloat16',byteCount=2*math.prod(shape))]) for name,shape,kind in roots]
        inert_tensors=[dict(t,loadedDType=t['dtype']) for m in inert for t in m['parameters']]
        load=dict(common,stageIndex=rank,sourceParameterLayoutSHA256=layout(union),
            stagePlanSHA256=digest(('invented-stage-'+str(rank)+str(spans)).encode()),
            constructionConfigurationSHA256=digest(('invented-construction-'+str(rank)+str(spans)).encode()),
            activeTensors=group,inertModules=inert,activeMappingSHA256=digest(canonical(group)),
            activeParameterLayoutSHA256=layout(group),parameterLayoutSHA256=layout(group+inert_tensors),
            loadedTensorBytes=sum(t['byteCount'] for t in group),inertTensorBytes=sum(t['byteCount'] for t in inert_tensors),
            largestHostTensorBytes=2*v*h,embeddingActivationDType='bfloat16')
        summary={key:load[key] for key in ('stageIndex','constructionConfigurationSHA256','stagePlanSHA256','activeMappingSHA256',
            'activeParameterLayoutSHA256','parameterLayoutSHA256','loadedTensorBytes','inertTensorBytes')}
        summaries.append(dict(summary,activeTensorCount=len(group),inertTensorCount=len(inert_tensors)));result.append(load)
    common['stages']=summaries
    for load in result:load.update(storageCommitment=copy.deepcopy(common),storageCommitmentSHA256=digest(canonical(common)))
    return result


def states(ctx,rank,tokens):
    text=ctx['text'];entries=[]
    for layer in range(*bounds(ctx)[rank]):
        if (layer+1)%text['full_attention_interval']==0:
            parts=[('kv.keys',[1,1,tokens,2],'bfloat16'),('kv.values',[1,1,tokens,2],'bfloat16'),('kv.position_offsets',[1],'int32')]
        else:parts=[('conv',[1,2,68],'bfloat16'),('ssm',[1,1,4,32],'float32')]
        for component,shape,dtype in parts:
            size=math.prod(shape)*WIDTH[dtype]
            entries.append(dict(globalLayerIndex=layer,component=component,shape=shape,dtype=dtype,byteCount=size,
                sha256=digest(f'invented-state:{layer}:{component}:{tokens}'.encode())))
    entries.sort(key=lambda t:(t['globalLayerIndex'],t['component']))
    material=['cbv2-owned-state-v1',f'tokens={tokens}']+[f"{t['globalLayerIndex']}|{t['component']}|{t['shape']}|{t['dtype']}|{t['byteCount']}|{t['sha256']}" for t in entries]
    return entries,sum(t['byteCount'] for t in entries),digest('\n'.join(material).encode())


def reports(ctx):
    source=loads(ctx);output=[]
    for rank in (0,1):
        load=source[rank];frames=[]
        identity=dict(stageIndex=rank,requestFingerprint=ctx['request_fingerprint'],artifactAggregateSHA256=ctx['artifact'],
            sourceConfigurationSHA256=ctx['configuration_sha256'],storageCommitmentSHA256=load['storageCommitmentSHA256'],
            planFingerprint=load['planSHA256'],stageFingerprint=load['stagePlanSHA256'],
            constructionConfigurationSHA256=load['constructionConfigurationSHA256'],bf16ConversionEnabled=True,activationDType='bfloat16')
        for step in ctx['request']['steps']:
            frame=step['frame'];tokens=frame['tokenOffset']+frame['tokenCount'];entries,size,fingerprint=states(ctx,rank,tokens)
            shape=[1,frame['tokenCount'],ctx['text']['hidden_size']];logits=frame['phase']=='decode' or frame['finalPromptChunk']
            capture=dict(kind='qwen_layer_stage_rank_frame_capture',identity=copy.deepcopy(identity),frame=copy.deepcopy(frame),
                committedTokens=tokens,sourceLayerStart=bounds(ctx)[rank][0],sourceLayerEnd=bounds(ctx)[rank][1],
                stateEntries=entries,logicalStateBytes=size,stageStateSHA256=fingerprint,
                boundaryPayloadSHA256=digest(str(frame).encode()),boundaryShape=shape,boundaryDType='bfloat16',
                outputKind='hidden' if rank==0 else 'logits' if logits else 'evaluation_handle',
                outputShape=shape if rank==0 else [1,ctx['vocabulary']] if logits else [1,1],outputDType='bfloat16')
            if rank==1 and logits:capture['logits']=dict(shape=[1,16],dtype='bfloat16',byteCount=32,logicalBytesSHA256=digest(bytes(32)),values=[0.0]*16)
            frames.append(dict(kind='qwen_layer_stage_rank_frame_completion',capture=capture,headerSHA256=digest(('header'+str(frame)).encode()),
                completedTransportPhase='consumed_ack_received_and_validated' if rank==0 else 'consumed_ack_send_completed'))
        output.append(dict(kind='qwen_layer_stage_rank_report',schemaVersion=1,rank=rank,worldSize=2,epoch=EPOCH,
            transport='loopback-test',backend='ring',completed=True,correctnessOnly=True,throughputMeasurementValid=False,
            modelForwardCompared=False,physicalTransferQualified=False,allRequestStateRetired=True,modelReleased=True,
            conservativeStateAndBoundaryBytes=65536,sourceLoad=load,request=copy.deepcopy(ctx['request']),frames=frames))
    return output


def baseline(ctx,rows):
    old,_=make_request('d'*32,ctx['request']['promptTokenIDs'],ctx['request']['teacherTokenIDs'],32,16)
    load=rows[0]['sourceLoad'];source=dict(artifactAggregateSHA256=ctx['artifact'],sourceConfigurationSHA256=ctx['configuration_sha256'],
        sourceParameterLayoutSHA256=load['sourceParameterLayoutSHA256'],planSHA256=load['planSHA256'],bf16ConversionEnabled=True,
        embeddingActivationDType='bfloat16',sourceModelTensorBytes=load['sourceModelTensorBytes'],
        layerCount=ctx['text']['num_hidden_layers'],vocabularySize=16)
    frames=[]
    for left,right in zip(rows[0]['frames'],rows[1]['frames']):
        a,b=left['capture'],right['capture'];merged=sorted(a['stateEntries']+b['stateEntries'],key=lambda t:(t['globalLayerIndex'],t['component']))
        value=dict(frame=a['frame'],committedTokens=a['committedTokens'],state=dict(committedTokens=a['committedTokens'],entries=merged,
            logicalByteCount=a['logicalStateBytes']+b['logicalStateBytes']))
        if 'logits' in b:value['logits']=b['logits']
        frames.append(value)
    return dict(kind='qwen_layer_stage_baseline_checkpoint',baselineModelReleasedBeforeStageLoading=True,
        baseline=dict(kind='qwen_layer_stage_recorded_baseline',correctnessOnly=True,throughputMeasurementValid=False,
            allRequestStateRetired=True,request=old,source=source,frames=frames))
