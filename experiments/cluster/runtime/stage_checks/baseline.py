"""Optional pinned evidence comparison, separate from successful rank execution."""
from .common import digest,exact,flags,parse,require,sha
from .evidence import logit_bytes
from . import request


def compare(path,records,context):
    with path.open('rb') as stream:raw=stream.read(64*1024**2+1)
    require(0<len(raw)<=64*1024**2 and digest(raw)==sha(context['baseline_sha256']),'Baseline bytes differ from their explicit pin/bound')
    rows=[parse(line) for line in raw.splitlines() if line.strip()]
    candidates=[row for row in rows if row.get('kind')=='qwen_layer_stage_baseline_checkpoint']
    require(len(candidates)==1,'Pinned baseline must contain exactly one native baseline checkpoint')
    flags(candidates[0],baselineModelReleasedBeforeStageLoading=True)
    baseline=candidates[0]['baseline'];require(baseline['kind']=='qwen_layer_stage_recorded_baseline','Wrong baseline namespace')
    flags(baseline,correctnessOnly=True,throughputMeasurementValid=False,allRequestStateRetired=True)
    old=baseline['request'];old_epoch=old['request']['requestID'].replace('-','')
    expected,_=request.make_request(old_epoch,old['promptTokenIDs'],old['teacherTokenIDs'],old['request']['chunkSize'],old['vocabularySize'])
    request.validate(old,expected);request.baseline_history(old,context['request'])
    source=baseline['source'];load=records[0]['sourceLoad']
    for key,value in [('artifactAggregateSHA256',context['artifact']),('sourceConfigurationSHA256',context['configuration_sha256']),
                      ('sourceParameterLayoutSHA256',load['sourceParameterLayoutSHA256']),('planSHA256',load['planSHA256']),
                      ('bf16ConversionEnabled',True),('embeddingActivationDType',load['embeddingActivationDType']),
                      ('sourceModelTensorBytes',load['sourceModelTensorBytes']),('layerCount',context['text']['num_hidden_layers']),
                      ('vocabularySize',context['vocabulary'])]:exact(source[key],value,'Baseline source identity differs: '+key)
    require(len(baseline['frames'])==len(records[0]['frames']),'Baseline frame count differs')
    logit_rows=0
    for original,left,right in zip(baseline['frames'],records[0]['frames'],records[1]['frames']):
        a,b=left['capture'],right['capture'];exact(original['frame'],a['frame'],'Baseline timeline differs')
        exact(original['committedTokens'],a['committedTokens'],'Baseline token frontier differs')
        exact(original['state']['committedTokens'],a['committedTokens'],'Baseline state frontier differs')
        merged=sorted(a['stateEntries']+b['stateEntries'],key=lambda item:(item['globalLayerIndex'],item['component']))
        exact(original['state']['entries'],merged,'Native global state metadata/hash differs from baseline')
        require(original['state']['logicalByteCount']==a['logicalStateBytes']+b['logicalStateBytes'],'Baseline state bytes differ')
        if b.get('logits')is None:require(original.get('logits')is None,'Unexpected baseline output row')
        else:
            require(logit_bytes(original['logits'],context['vocabulary'])==logit_bytes(b['logits'],context['vocabulary']),
                    'Native full-vocabulary logit bytes differ from baseline')
            logit_rows+=1
    return dict(performed=True,pinned_baseline_sha256=context['baseline_sha256'],exact_state_hashes=True,
                exact_native_logit_bytes=True,logit_rows=logit_rows,request_UUIDs_independently_bound=True,
                quality_or_throughput_qualification=False)
