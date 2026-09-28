"""Admit pinned baseline identity and final native dtype, not a candidate audit."""
from .common import FLOATS,canonical,digest,exact,flags,integer,parse,require,sha
from .evidence import logit_bytes,state_entries
from . import request


def frame_fingerprint(value,step,context,final_dtype):
    frame=step['frame'];tokens=frame['tokenOffset']+frame['tokenCount']
    exact(value['frame'],frame,'Baseline frame coordinates differ')
    exact(value['committedTokens'],tokens,'Baseline committed frontier differs')
    final=frame['finalPromptChunk'];kind='logits' if final else 'evaluation_handle'
    exact(value['outputKind'],kind,'Baseline output responsibility differs')
    shape=[1,context['vocabulary'] if final else 1]
    exact(value['outputShape'],shape,'Baseline output shape differs')
    dtype=value['outputDType'];require(dtype in FLOATS,'Baseline output dtype is unsupported')
    state=value['state'];exact(state['committedTokens'],tokens,'Baseline state frontier differs')
    entries=state['entries'];require(isinstance(entries,list),'Missing baseline state entries')
    half=context['text']['num_hidden_layers']//2
    require(entries==sorted(entries,key=lambda x:(x['globalLayerIndex'],x['component'])),
            'Baseline state entries must be ordered')
    total=0
    for rank in (0,1):
        owned=[entry for entry in entries if rank*half<=integer(entry['globalLayerIndex'],0,2*half-1)<(rank+1)*half]
        size,_=state_entries(owned,context['text'],rank,tokens);total+=size
    exact(state['logicalByteCount'],total,'Baseline state byte total differs')
    identities=[f"{x['globalLayerIndex']}|{x['component']}|{x['shape']}|{x['dtype']}|{x['byteCount']}|{x['sha256']}" for x in entries]
    state_hash=digest('\n'.join(['cbv2-owned-state-v1',f'tokens={tokens}']+identities).encode())
    exact(state['fingerprint'],state_hash,'Baseline state fingerprint differs')
    if final:
        require(dtype==final_dtype,'Explicit logits dtype differs from final baseline observation')
        logits=value['logits'];require(logits['dtype']==dtype,'Baseline row/output dtype differs')
        logit_bytes(logits,context['vocabulary'])
        logit_hash=sha(logits['logicalBytesSHA256'])
    else:
        require(value.get('logits') is None,'Intermediate baseline unexpectedly captures logits')
        logit_hash='no-logits'
    coordinate=f"{frame['sequence']}|{frame['phase']}|{frame['tokenOffset']}|{frame['tokenCount']}|{str(final).lower()}"
    return digest('\n'.join(['qwen-recorded-frame-v1',coordinate,f'tokens={tokens}',
        f'{kind}|{shape}|{dtype}',state_hash,logit_hash]).encode())


def admit(raw,context,expected_evidence,logits_dtype):
    require(logits_dtype in FLOATS,'Explicit native logits dtype required')
    require(digest(raw)==sha(context['baseline_sha256']),'Baseline file differs from explicit SHA256')
    require(0<len(raw)<=64*1024**2,'Baseline exceeds its byte bound')
    rows=[parse(line) for line in raw.splitlines() if line.strip()]
    require(all(isinstance(row,dict) for row in rows),'Baseline JSONL must contain objects')
    candidates=[row for row in rows if row.get('kind')=='qwen_layer_stage_baseline_checkpoint']
    require(len(candidates)==1,'Exactly one pinned native baseline checkpoint is required')
    flags(candidates[0],baselineModelReleasedBeforeStageLoading=True)
    baseline=candidates[0]['baseline']
    require(baseline['kind']=='qwen_layer_stage_recorded_baseline','Wrong baseline evidence namespace')
    flags(baseline,correctnessOnly=True,throughputMeasurementValid=False,allRequestStateRetired=True)
    old=baseline['request'];old_epoch=old['request']['requestID'].replace('-','')
    expected,_=request.make_request(old_epoch,old['promptTokenIDs'],old['teacherTokenIDs'],
                                    old['request']['chunkSize'],old['vocabularySize'])
    request.validate(old,expected);request.baseline_history(old,context['request'])
    source=baseline['source']
    known=dict(artifactAggregateSHA256=context['artifact'],sourceConfigurationSHA256=context['configuration_sha256'],
               bf16ConversionEnabled=True,layerCount=context['text']['num_hidden_layers'],vocabularySize=context['vocabulary'])
    require(set(source)==set(known)|{'sourceParameterLayoutSHA256','planSHA256','embeddingActivationDType','sourceModelTensorBytes'},
            'Baseline source identity schema differs')
    for key,value in known.items():exact(source[key],value,'Baseline source differs: '+key)
    for key in ('sourceParameterLayoutSHA256','planSHA256'):sha(source[key])
    integer(source['sourceModelTensorBytes'],1,6*1024**3)
    require(source['embeddingActivationDType'] in FLOATS,'Baseline native activation dtype is unsupported')
    frames=baseline['frames'];require(isinstance(frames,list) and len(frames)==3,'Baseline needs exactly three prefill frames')
    hashes=[frame_fingerprint(value,step,context,logits_dtype) for value,step in zip(frames,old['steps'])]
    fingerprint=digest('\n'.join(['qwen-layer-stage-baseline-v1',old['fingerprint'],digest(canonical(source))]+hashes).encode())
    require(fingerprint==sha(expected_evidence)==sha(baseline['fingerprint']),'Pinned native baseline evidence fingerprint differs')
    final=frames[-1]['logits']
    return dict(file_sha256=context['baseline_sha256'],evidence_sha256=fingerprint,source=source,
        native_dtype=source['embeddingActivationDType'],logits_dtype=logits_dtype,
        final_logit_sha256=final['logicalBytesSHA256'],final_state_sha256=frames[-1]['state']['fingerprint'],
        final_frontier=65,baseline_history_and_evidence_bound=True,candidate_numerical_comparison_performed=False,
        historical_build_or_execution_provenance_reverified=False)
