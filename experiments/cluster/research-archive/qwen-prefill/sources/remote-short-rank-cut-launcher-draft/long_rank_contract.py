"""Closed short-rank outer identity/retirement checks; numerical audit is separate."""
from long_reference_inputs import ARTIFACT, CONFIGURATION, require, is_sha256
from long_rank_configuration import policy
from long_rank_identity import canonical, recorded_request, request_fingerprint, validate_request
from short_cut_request import equal
from short_cut_expected import (PLAN_SHA256,SOURCE_LAYOUT_SHA256,SOURCE_MODEL_BYTES,
    STAGE_PLAN_SHA256,STAGE_CONFIGURATION_SHA256,NAMED_STATE_AND_BOUNDARY_BYTES)

READY, FINAL = 'qwen_layer_stage_rank_ready', 'qwen_layer_stage_rank_report'
COMMON={'kind','schemaVersion','epoch','rank','worldSize','transport','backend'}
FINAL_FIELDS={'completed','correctnessOnly','throughputMeasurementValid','modelForwardCompared','physicalTransferQualified',
    'sourceLoad','request','frames','allRequestStateRetired','modelReleased','conservativeStateAndBoundaryBytes','memory'}


def flags(record,**expected):
    for key,value in expected.items():
        require(type(record.get(key)) is bool and record[key] is value,'Wrong native flag: '+key)


def validate(record,index,rank,epoch,scheduling,inputs,first=None):
    policy(scheduling)
    require(type(record) is dict and set(record)==COMMON|(FINAL_FIELDS if index==1 else set()),'Unexpected short rank record fields')
    for key,value in dict(kind=READY if index==0 else FINAL,schemaVersion=1,epoch=epoch,rank=rank,
        worldSize=2,transport='loopback-test',backend='ring').items():
        require(type(record[key]) is type(value) and record[key]==value,'Rank identity differs: '+key)
    if index==0:return
    require(first is not None,'Missing ready record')
    flags(record,completed=True,correctnessOnly=True,throughputMeasurementValid=False,modelForwardCompared=False,
        physicalTransferQualified=False,allRequestStateRetired=True,modelReleased=True)
    equal(record['conservativeStateAndBoundaryBytes'],NAMED_STATE_AND_BOUNDARY_BYTES,'Wrong short named-state/boundary bound')
    validate_request(record['request'],epoch,inputs)
    source=record['sourceLoad'];require(type(source) is dict,'Missing verified source receipt')
    known=dict(schemaVersion=1,stageIndex=rank,verifiedAggregateSHA256=ARTIFACT,sourceConfigurationSHA256=CONFIGURATION,
        sourceParameterLayoutSHA256=SOURCE_LAYOUT_SHA256,sourceModelTensorBytes=SOURCE_MODEL_BYTES,
        planSHA256=PLAN_SHA256,stagePlanSHA256=STAGE_PLAN_SHA256[rank],
        constructionConfigurationSHA256=STAGE_CONFIGURATION_SHA256[rank],embeddingActivationDType='bfloat16',bf16ConversionEnabled=True)
    for key,value in known.items():equal(source.get(key),value,'Wrong verified source/cut identity: '+key)
    require(is_sha256(source.get('storageCommitmentSHA256')),'Invalid shared storage pin')
    frames=record['frames'];steps=recorded_request(epoch,inputs)['steps']
    require(type(frames) is list and len(frames)==6,'Incomplete short frame coverage')
    for completion,step in zip(frames,steps):
        require(type(completion) is dict and completion.get('kind')=='qwen_layer_stage_rank_frame_completion','Wrong frame completion namespace')
        capture=completion.get('capture');require(type(capture) is dict and capture.get('kind')=='qwen_layer_stage_rank_frame_capture','Wrong frame capture namespace')
        equal(capture.get('frame'),step['frame'],'Wrong frame coordinates/order')
        equal(capture.get('committedTokens'),step['frame']['tokenOffset']+step['frame']['tokenCount'],'Wrong committed frontier')
        equal([capture.get('sourceLayerStart'),capture.get('sourceLayerEnd')],[[0,12],[12,32]][rank],'Wrong cut stage range')
        identity=capture.get('identity');require(type(identity) is dict,'Missing captured stage identity')
        expected=dict(stageIndex=rank,requestFingerprint=request_fingerprint(epoch),artifactAggregateSHA256=ARTIFACT,
            sourceConfigurationSHA256=CONFIGURATION,storageCommitmentSHA256=source['storageCommitmentSHA256'],
            planFingerprint=PLAN_SHA256,stageFingerprint=STAGE_PLAN_SHA256[rank],
            constructionConfigurationSHA256=STAGE_CONFIGURATION_SHA256[rank],bf16ConversionEnabled=True,activationDType='bfloat16')
        for key,value in expected.items():equal(identity.get(key),value,'Wrong frame identity: '+key)
        require(is_sha256(completion.get('headerSHA256')) and is_sha256(capture.get('boundaryPayloadSHA256')),'Missing native boundary hashes')
        shape=capture.get('boundaryShape')
        require(type(shape) is list and len(shape)==3 and type(shape[2]) is int and 1<=shape[2]<=8192,'Invalid bounded residual shape')
        equal(shape[:2],[1,step['frame']['tokenCount']],'Residual batch/token shape differs')
        equal(capture.get('boundaryDType'),'bfloat16','Residual dtype differs from source activation policy')
        phase='consumed_ack_received_and_validated' if rank==0 else 'consumed_ack_send_completed'
        require(completion.get('completedTransportPhase')==phase,'Incomplete consumed acknowledgement')
    phases=['before_stage_load','stage_loaded_request_admitted','stage_request_retired_weights_resident','stage_model_released_cache_cleared']
    require(type(record['memory']) is list and len(record['memory'])==len(phases),'Native memory phase count differs')
    for row,phase in zip(record['memory'],phases):
        require(type(row) is dict and set(row)=={'phase','activeMLXBytes','cachedMLXBytes','peakMLXBytesSinceProcessStart'}
            and row['phase']==phase,'Native memory phase differs')
        require(all(type(row[key]) is int and row[key]>=0 for key in ('activeMLXBytes','cachedMLXBytes','peakMLXBytesSinceProcessStart')),'Invalid native memory counter')
    require(record['memory'][-1]['cachedMLXBytes']==0,'Native final cache clear differs')
    # State inventories, numerical values, logits and baseline equality stay
    # opaque here; the separately frozen short-rank oracle owns those checks.


def peers(readers):
    if not all(len(reader.rows)==2 for reader in readers):return
    a,b=(reader.rows[1] for reader in readers)
    require(canonical(a['request'])==canonical(b['request']),'Peers disagree on request history')
    for key in ('storageCommitmentSHA256','sourceParameterLayoutSHA256','sourceModelTensorBytes','planSHA256'):
        equal(a['sourceLoad'][key],b['sourceLoad'][key],'Peers disagree on source: '+key)
    for left,right in zip(a['frames'],b['frames']):
        require(left['headerSHA256']==right['headerSHA256'],'Peers disagree on boundary header')
        for key in ('boundaryPayloadSHA256','boundaryShape','boundaryDType'):
            equal(left['capture'].get(key),right['capture'].get(key),'Peers disagree on residual metadata: '+key)
