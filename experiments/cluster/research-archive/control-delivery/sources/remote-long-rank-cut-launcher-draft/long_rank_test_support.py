"""Fabricated metadata and process-shaped fakes; never executes native code."""
import json
from long_reference_inputs import ARTIFACT, CONFIGURATION
from long_rank_identity import canonical, sha, known_agreement, recorded_request, environment_receipt
from long_rank_warning import WARNING
from long_pair_cut import PLAN_SHA256, STAGE_PLAN_SHA256, STAGE_CONFIGURATION_SHA256, SOURCE_LAYOUT_SHA256, SOURCE_MODEL_BYTES

EPOCH = 'a' * 32
ENDPOINTS = [['127.0.0.1:31001'], ['127.0.0.1:31002']]
RAW_PROMPT = (json.dumps([3] * 8192,separators=(',',':')) + '\n').encode()
INPUTS = dict(prompt=[3] * 8192,teacher=[],prompt_file_sha256=sha(RAW_PROMPT),
    prompt_token_ids_sha256=sha(','.join(['3'] * 8192).encode()))


def fixtures(rank,scheduling='serial_v1',plan=PLAN_SHA256,epoch=EPOCH,inputs=INPUTS,storage='b' * 64):
    descriptor = known_agreement(epoch,scheduling,inputs)
    descriptor.update(storageCommitmentSHA256=storage,planFingerprint=plan,
        producerStageFingerprint=STAGE_PLAN_SHA256[0],consumerStageFingerprint=STAGE_PLAN_SHA256[1],
        producerConstructionConfigurationSHA256=STAGE_CONFIGURATION_SHA256[0],
        consumerConstructionConfigurationSHA256=STAGE_CONFIGURATION_SHA256[1])
    fingerprint = sha(b'qwen-profiled-prefill-start-agreement-v1\n' + canonical(descriptor))
    common = dict(schemaVersion=1,epoch=epoch,rank=rank,worldSize=2,transport='loopback-test',backend='ring',
        flow='profiled_prefill_measurement_v1',envelopeVersion=4,agreement=descriptor,agreementFingerprint=fingerprint,
        promptFileSHA256=inputs['prompt_file_sha256'])
    ready = dict(common,kind='qwen_long_prefill_rank_ready',modelsReadyAgreementValidated=True,freshRequestStateCreated=False)
    final = dict(common,kind='qwen_long_prefill_rank_report',completed=True,correctnessOnly=True,
        throughputMeasurementValid=False,modelForwardCompared=False,physicalTransferQualified=False,
        sourceLoad=dict(stageIndex=rank,verifiedAggregateSHA256=ARTIFACT,sourceConfigurationSHA256=CONFIGURATION,
                        storageCommitmentSHA256=descriptor['storageCommitmentSHA256'],planSHA256=plan,
                        stagePlanSHA256=STAGE_PLAN_SHA256[rank],constructionConfigurationSHA256=STAGE_CONFIGURATION_SHA256[rank],
                        sourceParameterLayoutSHA256=SOURCE_LAYOUT_SHA256,sourceModelTensorBytes=SOURCE_MODEL_BYTES),
        request=recorded_request(epoch,inputs['prompt']),arithmeticEnvironment=environment_receipt(),
        arithmeticEnvironmentSHA256=descriptor['arithmeticEnvironmentSHA256'],
        resourceAdmission={'fabricated':'opaque resource admission'},execution={'fabricated':'not a numerical fixture'},
        allRequestStateRetired=True,modelReleased=True,
        memory=[dict(phase=phase,activeMLXBytes=0,cachedMLXBytes=0,peakMLXBytesSinceProcessStart=100) for phase in
            ['before_stage_load','stage_loaded_no_request_state','stage_request_retired_weights_resident','stage_model_released_cache_cleared']])
    return [ready,final]


class Child:
    def __init__(self,pid,code): self.pid,self.code,self.waits = pid,code,0
    def poll(self): return self.code
    def wait(self,timeout=0):
        if self.code is None: raise AssertionError('Fake wait on running process')
        self.waits += 1; return self.code


def write_records(directory,rows,stderr=WARNING):
    (directory / 'stdout.jsonl').write_bytes(b''.join(canonical(row) + b'\n' for row in rows))
    (directory / 'stderr.log').write_bytes(stderr)
