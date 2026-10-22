"""Fabricated metadata and process-shaped fakes; never executes native code."""
import json
from long_reference_inputs import ARTIFACT, CONFIGURATION
from long_rank_identity import canonical, sha, known_agreement, recorded_request, environment_receipt
from long_rank_warning import WARNING

EPOCH = 'a' * 32
ENDPOINTS = [['127.0.0.1:31001'], ['127.0.0.1:31002']]
RAW_PROMPT = (json.dumps([3] * 8192,separators=(',',':')) + '\n').encode()
INPUTS = dict(prompt=[3] * 8192,teacher=[],prompt_file_sha256=sha(RAW_PROMPT),
    prompt_token_ids_sha256=sha(','.join(['3'] * 8192).encode()))


def fixtures(rank,scheduling='serial_v1',plan='b' * 64,epoch=EPOCH,inputs=INPUTS):
    descriptor = known_agreement(epoch,scheduling,inputs)
    descriptor.update(storageCommitmentSHA256='b' * 64,planFingerprint=plan,
        producerStageFingerprint='c' * 64,consumerStageFingerprint='d' * 64,
        producerConstructionConfigurationSHA256='e' * 64,consumerConstructionConfigurationSHA256='f' * 64)
    fingerprint = sha(b'qwen-profiled-prefill-start-agreement-v1\n' + canonical(descriptor))
    common = dict(schemaVersion=1,epoch=epoch,rank=rank,worldSize=2,transport='loopback-test',backend='ring',
        flow='profiled_prefill_measurement_v1',envelopeVersion=4,agreement=descriptor,agreementFingerprint=fingerprint,
        promptFileSHA256=inputs['prompt_file_sha256'])
    ready = dict(common,kind='qwen_long_prefill_rank_ready',modelsReadyAgreementValidated=True,freshRequestStateCreated=False)
    final = dict(common,kind='qwen_long_prefill_rank_report',completed=True,correctnessOnly=True,
        throughputMeasurementValid=False,modelForwardCompared=False,physicalTransferQualified=False,
        sourceLoad=dict(stageIndex=rank,verifiedAggregateSHA256=ARTIFACT,sourceConfigurationSHA256=CONFIGURATION,
                        storageCommitmentSHA256=descriptor['storageCommitmentSHA256']),
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
