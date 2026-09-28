"""qwen_layer_stage_rank_report v1: source, request, residual, state and logit namespaces."""
from .common import FLOATS,canonical,digest,envelope,exact,flags,integer,require,sha
from .evidence import logit_bytes,state_entries
from . import request,storage,stage_ranges

READY='qwen_layer_stage_rank_ready'
TERMINAL='qwen_layer_stage_rank_report'
MAX_STDOUT=64*1024**2
MAX_LINE=60*1024**2


def validate(record,rank,epoch,context):
    start,end=stage_ranges.for_context(context)[integer(rank,0,1)]
    kind=record.get('kind');require(kind in(READY,TERMINAL),'Wrong stage evidence namespace')
    envelope(record,kind,rank,epoch)
    if kind==READY:return
    flags(record,completed=True,correctnessOnly=True,throughputMeasurementValid=False,modelForwardCompared=False,
          physicalTransferQualified=False,allRequestStateRetired=True,modelReleased=True)
    integer(record['conservativeStateAndBoundaryBytes'],1,512*1024**2)
    source=record['sourceLoad'];require(type(source['stageIndex'])is int and source['stageIndex']==rank,'Wrong loaded stage')
    require(source['verifiedAggregateSHA256']==context['artifact'] and source['sourceConfigurationSHA256']==context['configuration_sha256'],'Wrong source pin/configuration')
    request.validate(record['request'],context['request'])
    frames=record['frames'];steps=context['request']['steps'];text=context['text']
    require(isinstance(frames,list) and len(frames)==len(steps),'Incomplete stage frame coverage')
    for item,step in zip(frames,steps):
        require(item['kind']=='qwen_layer_stage_rank_frame_completion','Wrong frame completion namespace')
        capture=item['capture'];require(capture['kind']=='qwen_layer_stage_rank_frame_capture','Wrong frame capture namespace')
        exact(capture['frame'],step['frame'],'Wrong frame order/coordinates')
        tokens=step['frame']['tokenOffset']+step['frame']['tokenCount']
        require(integer(capture['committedTokens'])==tokens,'Wrong committed token frontier')
        require(integer(capture['sourceLayerStart'])==start and integer(capture['sourceLayerEnd'])==end,'Wrong global stage range')
        identity=capture['identity'];require(integer(identity['stageIndex'])==rank,'Wrong captured rank')
        for key,value in [('requestFingerprint',context['request_fingerprint']),('artifactAggregateSHA256',context['artifact']),
                          ('sourceConfigurationSHA256',context['configuration_sha256']),('storageCommitmentSHA256',source['storageCommitmentSHA256']),
                          ('planFingerprint',source['planSHA256']),('stageFingerprint',source['stagePlanSHA256']),
                          ('constructionConfigurationSHA256',source['constructionConfigurationSHA256'])]:
            require(identity[key]==value,'Wrong captured identity: '+key);sha(value)
        require(identity['bf16ConversionEnabled']is True and identity['activationDType']==source['embeddingActivationDType']in FLOATS,'Wrong captured activation policy')
        dtype=identity['activationDType'];shape=[1,step['frame']['tokenCount'],text['hidden_size']]
        exact(capture['boundaryShape'],shape,'Residual shape differs');require(capture['boundaryDType']==dtype,'Residual dtype differs')
        sha(item['headerSHA256']);sha(capture['boundaryPayloadSHA256'])
        total,fingerprint=state_entries(capture['stateEntries'],text,rank,tokens,context.get('stage_cut'))
        require(integer(capture['logicalStateBytes'])==total and sha(capture['stageStateSHA256'])==fingerprint,'State accounting/hash differs')
        expects_logits=step['frame']['phase']=='decode' or step['frame']['finalPromptChunk']
        expected_kind='hidden' if rank==0 else 'logits' if expects_logits else 'evaluation_handle'
        require(capture['outputKind']==expected_kind,'Wrong rank output responsibility')
        expected_shape=shape if rank==0 else [1,context['vocabulary']] if expects_logits else [1,1]
        exact(capture['outputShape'],expected_shape,'Wrong output shape')
        require(capture['outputDType']in FLOATS,'Unsupported output dtype')
        if rank==0:require(capture['outputDType']==dtype,'Hidden output/residual dtype differs')
        if rank==1 and expects_logits:
            require(capture['logits']['dtype']==capture['outputDType'],'Native output/logit dtype differs')
            logit_bytes(capture['logits'],context['vocabulary'])
        else:require(capture.get('logits')is None,'Unexpected logits on a non-logit output')
        phase='consumed_ack_received_and_validated' if rank==0 else 'consumed_ack_send_completed'
        require(item['completedTransportPhase']==phase,'Incomplete consumed acknowledgement')


def pair(records,context):
    a,b=records
    inventory=storage.validate_pair([a['sourceLoad'],b['sourceLoad']],context)
    exact(a['request'],b['request'],'Peer request differs')
    common=('requestFingerprint','artifactAggregateSHA256','storageCommitmentSHA256','bf16ConversionEnabled',
            'sourceConfigurationSHA256','planFingerprint','activationDType')
    for left,right in zip(a['frames'],b['frames']):
        for key in common:exact(left['capture']['identity'][key],right['capture']['identity'][key],'Peer identity differs: '+key)
        for key in ('boundaryPayloadSHA256','boundaryShape','boundaryDType'):
            exact(left['capture'][key],right['capture'][key],'Peer residual metadata differs')
        require(left['headerSHA256']==right['headerSHA256'],'Peer header hash differs')
    return dict(namespace=TERMINAL,schema_version=1,frames_per_rank=len(a['frames']),storage=inventory,
                native_logit_hashes_verified=True,state_namespace_hashes_verified=True,baseline_compared=False)
