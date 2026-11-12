"""Fabricated short DTOs and process handles; no candidate/model input reads."""
from long_reference_inputs import ARTIFACT, CONFIGURATION
from long_rank_identity import canonical,sha,recorded_request,request_fingerprint
from short_cut_expected import (PLAN_SHA256,SOURCE_LAYOUT_SHA256,SOURCE_MODEL_BYTES,STAGE_PLAN_SHA256,
    STAGE_CONFIGURATION_SHA256,NAMED_STATE_AND_BOUNDARY_BYTES)
from short_cut_test_fixture import (RAW_PROMPT,RAW_TEACHER,RAW_ORIGIN,RAW_PREFIX,RAW_TEXT,pinned_inputs,
    PROMPT,TEACHER,inputs as fixture_inputs)
from long_rank_warning import WARNING

EPOCH='a'*32
ENDPOINTS=[['127.0.0.1:31001'],['127.0.0.1:31002']]
INPUTS=fixture_inputs()


def fixtures(rank,scheduling=None,plan=PLAN_SHA256,epoch=EPOCH,inputs=INPUTS,storage='b'*64):
    request=recorded_request(epoch,inputs)
    common=dict(schemaVersion=1,epoch=epoch,rank=rank,worldSize=2,transport='loopback-test',backend='ring')
    ready=dict(common,kind='qwen_layer_stage_rank_ready')
    source=dict(schemaVersion=1,stageIndex=rank,verifiedAggregateSHA256=ARTIFACT,sourceConfigurationSHA256=CONFIGURATION,
        sourceParameterLayoutSHA256=SOURCE_LAYOUT_SHA256,sourceModelTensorBytes=SOURCE_MODEL_BYTES,planSHA256=plan,
        stagePlanSHA256=STAGE_PLAN_SHA256[rank],constructionConfigurationSHA256=STAGE_CONFIGURATION_SHA256[rank],
        embeddingActivationDType='bfloat16',bf16ConversionEnabled=True,storageCommitmentSHA256=storage)
    frames=[]
    for step in request['steps']:
        frame=step['frame'];capture=dict(kind='qwen_layer_stage_rank_frame_capture',frame=frame,
            committedTokens=frame['tokenOffset']+frame['tokenCount'],sourceLayerStart=[0,12][rank],sourceLayerEnd=[12,32][rank],
            identity=dict(stageIndex=rank,requestFingerprint=request_fingerprint(epoch),artifactAggregateSHA256=ARTIFACT,
                sourceConfigurationSHA256=CONFIGURATION,storageCommitmentSHA256=storage,planFingerprint=plan,
                stageFingerprint=STAGE_PLAN_SHA256[rank],constructionConfigurationSHA256=STAGE_CONFIGURATION_SHA256[rank],
                bf16ConversionEnabled=True,activationDType='bfloat16'),boundaryPayloadSHA256='d'*64,
                boundaryShape=[1,frame['tokenCount'],4096],boundaryDType='bfloat16')
        frames.append(dict(kind='qwen_layer_stage_rank_frame_completion',capture=capture,headerSHA256='e'*64,
            completedTransportPhase='consumed_ack_received_and_validated' if rank==0 else 'consumed_ack_send_completed'))
    final=dict(common,kind='qwen_layer_stage_rank_report',completed=True,correctnessOnly=True,throughputMeasurementValid=False,
        modelForwardCompared=False,physicalTransferQualified=False,sourceLoad=source,request=request,frames=frames,
        allRequestStateRetired=True,modelReleased=True,conservativeStateAndBoundaryBytes=NAMED_STATE_AND_BOUNDARY_BYTES,
        memory=[dict(phase=phase,activeMLXBytes=0,cachedMLXBytes=0,peakMLXBytesSinceProcessStart=100) for phase in
            ['before_stage_load','stage_loaded_request_admitted','stage_request_retired_weights_resident','stage_model_released_cache_cleared']])
    return [ready,final]


class Child:
    def __init__(self,pid,code):self.pid,self.code,self.waits=pid,code,0
    def poll(self):return self.code
    def wait(self,timeout=0):
        if self.code is None:raise AssertionError('Fake wait on running process')
        self.waits+=1;return self.code


def write_records(directory,rows,stderr=WARNING):
    (directory/'stdout.jsonl').write_bytes(b''.join(canonical(row)+b'\n' for row in rows))
    (directory/'stderr.log').write_bytes(stderr)
