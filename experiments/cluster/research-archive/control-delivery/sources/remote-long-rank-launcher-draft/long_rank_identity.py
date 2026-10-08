"""Source-derived local profile/history identities; no model or numerical oracle."""
import hashlib
import json
import uuid
from long_reference_inputs import ARTIFACT, CONFIGURATION, PROFILE, PROFILE_SHA256, VOCABULARY, require
from long_rank_configuration import REQUIRED_ENVIRONMENT

FLOW = 'profiled_prefill_measurement_v1'


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False, allow_nan=False).encode()


def sha(data):
    return hashlib.sha256(data).hexdigest()


def request_identity(epoch, prompt):
    identifier = str(uuid.UUID(hex=epoch))
    fingerprint = sha('\n'.join(['qwen-stage-profiled-prefill-request-v1', PROFILE, PROFILE_SHA256,
        identifier, 'batch=1', 'prompt=8192', 'chunk=512', 'output=1']).encode())
    recorded = sha('\n'.join(['qwen-layer-stage-profiled-prefill-recorded-request-v1', PROFILE, PROFILE_SHA256,
        fingerprint, 'vocabulary=' + str(VOCABULARY), 'prompt=' + ','.join(map(str, prompt)), 'teacher=']).encode())
    return identifier, fingerprint, recorded


def recorded_request(epoch, prompt):
    identifier, _, fingerprint = request_identity(epoch, prompt)
    steps = []
    for index in range(16):
        offset = index * 512
        steps.append(dict(frame=dict(phase='prefill', sequence=index, tokenOffset=offset, tokenCount=512,
            finalPromptChunk=index == 15), tokenIDs=prompt[offset:offset + 512], committedTokens=offset + 512))
    return dict(request=dict(profile=PROFILE, requestID=identifier, batchSize=1,
        promptCount=8192, chunkSize=512, outputCount=1), vocabularySize=VOCABULARY,
        promptTokenIDs=prompt, teacherTokenIDs=[], steps=steps, fingerprint=fingerprint)


def validate_request(actual, epoch, inputs):
    require(type(actual) is dict and type(actual.get('request')) is dict, 'Missing profiled request')
    expected = recorded_request(epoch, inputs['prompt'])
    copied = dict(actual, request=dict(actual['request']))
    identifier = copied['request'].get('requestID')
    require(type(identifier) is str and str(uuid.UUID(identifier)) == str(uuid.UUID(hex=epoch)), 'Request UUID differs from epoch')
    copied['request']['requestID'] = str(uuid.UUID(identifier))
    require(canonical(copied) == canonical(expected), 'Exact admitted raw-prompt history differs')


def environment_receipt():
    return dict(contract='qwen_cbv2_query128_bf16_tf32_default_v1', requiredValues=dict(REQUIRED_ENVIRONMENT),
        requiredAbsentNames=['MLX_METAL_GPU_ARCH', 'MLX_SDPA_BLOCKS'], full512TokenChunkQueryBlocks=4,
        defaultBindings={
            'MLX_METAL_GPU_ARCH': 'detect actual Metal device architecture; no override',
            'MLX_SDPA_BLOCKS': 'source default 0; native adaptive block selection',
            'MLX_ENABLE_TF32': 'explicit 1 matches pinned source default; permits eligible NAX paths',
            'DARKBLOOM_BF16_WEIGHTS': 'explicit 1 converts stored Float16 tensors to BFloat16 before subsequent arithmetic',
            'DARKBLOOM_CBV2_ATTN_QUERY_BLOCK': 'explicit 128 matches pinned source default; chunk512 uses four query blocks'},
        actualProcessEnvironmentMustBePassedBeforeMLXInitialization=True,
        sourceBinaryMetalLibraryAndHardwareIdentityStillRequired=True, sameChunkFullModelReferenceStillRequired=True,
        doesNotValidateOtherTimingOrResourceEnvironment=True, numericalOrPerformanceQualificationEstablished=False)


def known_agreement(epoch, scheduling, inputs):
    identifier, fingerprint, recorded = request_identity(epoch, inputs['prompt'])
    return dict(version=4, flow=FLOW, profile=PROFILE, profileFingerprint=PROFILE_SHA256,
        schedulingPolicy=scheduling, epoch=epoch, requestID=identifier, requestFingerprint=fingerprint,
        recordedRequestFingerprint=recorded, promptCount=8192, chunkSize=512, outputCount=1, batchSize=1,
        frameCount=16, vocabularySize=VOCABULARY, hiddenSize=4096,
        promptTokenIDsSHA256=inputs['prompt_token_ids_sha256'], sourceConfigurationSHA256=CONFIGURATION,
        artifactAggregateSHA256=ARTIFACT, bf16ConversionEnabled=True, nativeDType='bfloat16', logitsDType='bfloat16',
        arithmeticEnvironmentSHA256=sha(canonical(environment_receipt())),
        selectionPolicy='mlx_argmax_all_axes_with_finite_guard_v1')
