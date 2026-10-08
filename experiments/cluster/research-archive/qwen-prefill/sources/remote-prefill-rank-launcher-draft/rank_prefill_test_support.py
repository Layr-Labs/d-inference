"""Inert CPU fixtures for the draft launcher tests."""
import hashlib
import json
import uuid
from prefill_compute_inputs import ARTIFACT, CONFIGURATION, VOCABULARY, expected_frames, request_fingerprint, recorded_fingerprint

PROMPT, EPOCH = [3] * 65, 'a' * 32
ENDPOINTS = [['127.0.0.1:31001'], ['127.0.0.1:31002']]


def fixtures(rank, scheduling='serial_v1', plan='b' * 64):
    identifier = str(uuid.UUID(hex=EPOCH))
    descriptor = dict(version=3, flow='bounded_prefill_measurement_v1', schedulingPolicy=scheduling, epoch=EPOCH,
        requestID=identifier, requestFingerprint=request_fingerprint(EPOCH), recordedRequestFingerprint=recorded_fingerprint(EPOCH, PROMPT),
        promptCount=65, chunkSize=32, outputCount=1, batchSize=1, frameCount=3,
        promptTokenIDsSHA256=hashlib.sha256(','.join(map(str, PROMPT)).encode()).hexdigest(),
        sourceConfigurationSHA256=CONFIGURATION, artifactAggregateSHA256=ARTIFACT, storageCommitmentSHA256='b' * 64,
        planFingerprint=plan, producerStageFingerprint='b' * 64, consumerStageFingerprint='c' * 64,
        producerConstructionConfigurationSHA256='d' * 64, consumerConstructionConfigurationSHA256='e' * 64,
        bf16ConversionEnabled=True, hiddenSize=4096, nativeDType='bfloat16', logitsDType='bfloat16',
        vocabularySize=VOCABULARY, selectionPolicy='mlx_argmax_all_axes_with_finite_guard_v1')
    fingerprint = hashlib.sha256(b'qwen-prefill-start-agreement-v1\n' + json.dumps(
        descriptor, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()).hexdigest()
    common = dict(schemaVersion=1, epoch=EPOCH, rank=rank, worldSize=2, transport='loopback-test', backend='ring',
                  flow='bounded_prefill_measurement_v1', envelopeVersion=3, agreement=descriptor, agreementFingerprint=fingerprint)
    ready = dict(common, kind='qwen_layer_stage_prefill_rank_ready', modelsReadyAgreementValidated=True, freshRequestStateCreated=False)
    request = dict(request=dict(requestID=identifier, promptCount=65, chunkSize=32, outputCount=1),
        vocabularySize=VOCABULARY, promptTokenIDs=PROMPT, teacherTokenIDs=[], fingerprint=recorded_fingerprint(EPOCH, PROMPT),
        steps=[dict(frame=frame, tokenIDs=PROMPT[frame['tokenOffset']:frame['tokenOffset'] + frame['tokenCount']]) for frame in expected_frames()])
    final = dict(common, kind='qwen_layer_stage_prefill_rank_report', completed=True, correctnessOnly=True,
        throughputMeasurementValid=False, modelForwardCompared=False, physicalTransferQualified=False,
        sourceLoad=dict(verifiedAggregateSHA256=ARTIFACT, sourceConfigurationSHA256=CONFIGURATION), request=request,
        execution=dict(opaqueNativeOwnerResult=True), allRequestStateRetired=True, modelReleased=True,
        conservativeStateAndBoundaryBytes=1024, memory=[])
    return [ready, final]


class Child:
    def __init__(self, rank, code):
        self.pid, self.code, self.waits = 7001 + rank, code, 0
    def poll(self): return self.code
    def wait(self, timeout):
        assert self.code is not None
        self.waits += 1
        return self.code
