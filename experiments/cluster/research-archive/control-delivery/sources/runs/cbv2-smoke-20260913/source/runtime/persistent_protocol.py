"""Strict identity and request contracts for the experimental native worker."""

import hashlib
import re

from .persistent_io import PersistentCohortError, canonical
from .reports import validate_run
from .model_profiles import MODEL_FAMILIES, synthetic_identity
from .partition_storage import commitment_hash, validate_storage


VERSION = 4
IDENTITY_KEYS = set('model modelFamily configurationSHA256 parameterLayoutSHA256s partition partitionPlanSHA256 partitionStorageSHA256 attentionOutputPrecision ffnBranchPrecision executionPath vocabularySize layerCount feedForwardKind embeddingActivationDType ffnScaleDTypes syntheticWeights syntheticDType syntheticProfile seed bf16ConversionEnabled verifiedAggregateSHA256 transport tokenSelectionPolicy textOnly mtpEnabled'.split())
LIMITS = dict(maxOutputTokens=4096, maxChunkSize=32768, maxTimeoutSeconds=300,
              maxRequestsPerEpoch=4096, maxCapturedLogitValues=1048576, maxLineBytes=2097152)
FRAME_KEYS = {
    'ready': set('version type epoch rank worldSize pid modelLoadID modelLoadCount identity identitySHA256 limits parameterLayoutSHA256'.split()),
    'accepted': set('version type epoch rank sequence requestID requestSHA256 modelLoadID'.split()),
    'token': set('version type epoch rank sequence requestID step token'.split()),
    'completed': set('version type epoch rank sequence requestID requestSHA256 modelLoadID result'.split()),
    'stopped': set('version type epoch rank sequence'.split()),
}
RESULT_KEYS = set('iteration promptTokens generatedTokens localArgmaxTokens localArgmaxDisagreementCount decodeInputTokens prefillSeconds prefillTokensPerSecond decodeForwardCount decodeSeconds decodeStepSeconds peakMLXBytes activeMLXBytes'.split())


def need(condition, message):
    if not condition:
        raise PersistentCohortError(message)


def same(value, expected, name):
    need(type(value) is type(expected) and value == expected, f'Worker {name} differs from its contract')


def fingerprint(value):
    return isinstance(value, str) and re.fullmatch('[0-9a-f]{64}', value) is not None


def hash_frame(value):
    return hashlib.sha256(canonical(value)).hexdigest()


def frame(value, kind, epoch, rank, sequence=None, request=None, load_id=None):
    allowed = FRAME_KEYS[kind] | ({'logits'} if kind == 'completed' else set())
    if kind == 'ready':
        allowed |= {'partitionStorage'}
    need(isinstance(value, dict) and set(value) <= allowed and FRAME_KEYS[kind] <= set(value),
         f'Worker {kind} frame has missing or unknown fields')
    for key, expected in dict(version=VERSION, type=kind, epoch=epoch, rank=rank).items():
        same(value.get(key), expected, key)
    if sequence is not None:
        same(value.get('sequence'), sequence, 'sequence')
    if request is not None:
        same(value.get('requestID'), request['requestID'], 'requestID')
        if kind in ('accepted', 'completed'):
            same(value.get('requestSHA256'), hash_frame(request), 'requestSHA256')
            same(value.get('modelLoadID'), load_id, 'modelLoadID')
    return value


def ready(value, epoch, rank, spec):
    frame(value, 'ready', epoch, rank)
    cooperative = spec['backend'] in ('loopback-test', 'jaccl')
    same(value['worldSize'], 2 if cooperative else 1, 'worldSize')
    same(value['modelLoadCount'], 1, 'modelLoadCount')
    need(type(value['pid']) is int and value['pid'] > 0, 'Worker PID must be positive')
    need(isinstance(value['modelLoadID'], str) and 0 < len(value['modelLoadID']) <= 256,
         'Worker modelLoadID is missing or too long')
    identity, work = value['identity'], spec['workload']
    need(isinstance(identity, dict) and set(identity) == IDENTITY_KEYS, 'Worker identity fields differ')
    same(value['identitySHA256'], hash_frame(identity), 'identitySHA256')
    synthetic = bool(work.get('synthetic'))
    expected = dict(partition=spec['partition'] if cooperative else 'none',
        attentionOutputPrecision=work['attention_output_precision'], syntheticWeights=synthetic,
        ffnBranchPrecision=work['ffn_branch_precision'],
        executionPath=work['execution_path'],
        syntheticDType=work['synthetic_dtype'] if synthetic else 'none',
        syntheticProfile=work['synthetic_profile'] if synthetic else 'none', seed=str(work['seed']),
        bf16ConversionEnabled=not synthetic, transport=spec['backend'] if cooperative else 'none',
        tokenSelectionPolicy='rank0-greedy' if cooperative else 'local-greedy', textOnly=True, mtpEnabled=False,
        verifiedAggregateSHA256=spec['artifact_aggregate_sha256'] if cooperative and not synthetic else 'none')
    if synthetic:
        expected.update(synthetic_identity(work))
        expected.update(embeddingActivationDType=work['synthetic_dtype'], ffnScaleDTypes=[work['synthetic_dtype']])
    for key, expected_value in expected.items():
        same(identity.get(key), expected_value, 'identity.' + key)
    need(isinstance(identity['model'], str) and bool(identity['model'].strip()), 'Worker model identity is empty')
    need(identity['modelFamily'] in MODEL_FAMILIES, 'Unsupported worker model family')
    need(identity['modelFamily'] != 'gemma4' or
         (identity['partition'] != 'full' and identity['attentionOutputPrecision'] == 'native'),
         'Gemma supports FFN partitioning and native attention precision only')
    need(identity['modelFamily'] == 'gemma4' or identity['ffnBranchPrecision'] == 'native',
         'Float32 FFN branch precision requires a Gemma model')
    need(identity['executionPath'] != 'cbv2-contiguous' or
         (identity['modelFamily'] == 'qwen35' and identity['feedForwardKind'] == 'dense'),
         'CBv2 contiguous execution currently requires a dense Qwen model')
    need(fingerprint(identity['configurationSHA256']), 'Worker configurationSHA256 must be a SHA256')
    layouts = identity['parameterLayoutSHA256s']
    need(isinstance(layouts, list) and len(layouts) == value['worldSize'] and all(fingerprint(x) for x in layouts),
         'Worker parameter layout list differs from world size')
    same(value['parameterLayoutSHA256'], layouts[rank], 'parameterLayoutSHA256')
    if cooperative:
        try:
            storage = value.get('partitionStorage')
            validate_storage(storage, spec['partition'], rank, value['parameterLayoutSHA256'])
        except ValueError as error:
            raise PersistentCohortError(str(error)) from error
        same([entry['parameterLayoutSHA256'] for entry in storage['ranks']], layouts, 'committed parameter layouts')
        same(identity['partitionStorageSHA256'], commitment_hash(storage), 'partitionStorageSHA256')
    else:
        need('partitionStorage' not in value, 'Solo ready must omit partitionStorage')
        same(identity['partitionStorageSHA256'], 'none', 'partitionStorageSHA256')
    need(fingerprint(identity['partitionPlanSHA256']) if cooperative else identity['partitionPlanSHA256'] == 'none',
         'Worker partition plan identity differs')
    for key in ('vocabularySize', 'layerCount'):
        need(type(identity[key]) is int and 0 < identity[key] <= 2**30, f'Invalid worker {key}')
    need(identity['feedForwardKind'] in ('dense', 'moe'), 'Invalid worker FFN kind')
    need(identity['embeddingActivationDType'] in ('float16', 'bfloat16', 'float32'), 'Invalid worker activation dtype')
    scales = identity['ffnScaleDTypes']
    need(isinstance(scales, list) and scales and all(x in ('float16', 'bfloat16', 'float32') for x in scales)
         and len(set(scales)) == len(scales), 'Invalid worker FFN scale dtypes')
    limits = value['limits']
    need(isinstance(limits, dict) and set(limits) == set(LIMITS) | {'maxContextTokens', 'idleTimeoutSeconds'},
         'Worker limits fields differ')
    for key, expected_value in {**LIMITS, 'idleTimeoutSeconds': spec['timeout_seconds']}.items():
        same(limits.get(key), expected_value, 'limits.' + key)
    need(type(limits['maxContextTokens']) is int and 0 < limits['maxContextTokens'] <= 32768,
         'Invalid context limit')
    return value


def request(epoch, sequence, request_id, prompt, output_tokens, chunk_size, teacher_tokens,
            capture_logits, timeout_seconds, ready_record):
    limits, identity = ready_record['limits'], ready_record['identity']
    def require(condition, message):
        if not condition:
            raise ValueError(message)
    require(isinstance(request_id, str) and re.fullmatch(r'[A-Za-z0-9_.:-]{1,128}', request_id), 'Invalid request_id')
    require(type(sequence) is int and 1 <= sequence <= limits['maxRequestsPerEpoch'], 'Epoch request limit reached')
    for name, value, maximum in [('output_tokens', output_tokens, limits['maxOutputTokens']),
                                  ('chunk_size', chunk_size, limits['maxChunkSize']),
                                  ('timeout_seconds', timeout_seconds, limits['maxTimeoutSeconds'])]:
        require(type(value) is int and 1 <= value <= maximum, f'Invalid {name}')
    vocabulary = identity['vocabularySize']
    require(isinstance(prompt, list) and prompt and all(type(t) is int and 0 <= t < vocabulary for t in prompt),
            'Prompt must contain valid token IDs')
    require(len(prompt) + output_tokens <= limits['maxContextTokens'], 'Request exceeds context limit')
    require(type(capture_logits) is bool, 'capture_logits must be Boolean')
    require(not capture_logits or output_tokens * vocabulary <= limits['maxCapturedLogitValues'], 'Logit capture exceeds limit')
    if teacher_tokens is not None:
        require(isinstance(teacher_tokens, list) and len(teacher_tokens) == output_tokens - 1 and
                all(type(t) is int and 0 <= t < vocabulary for t in teacher_tokens), 'Teacher token history has invalid IDs or length')
    result = dict(version=VERSION, type='infer', epoch=epoch, sequence=sequence, requestID=request_id,
                  prompt=list(prompt), outputTokens=output_tokens, chunkSize=chunk_size,
                  timeoutSeconds=timeout_seconds, captureLogits=capture_logits)
    if teacher_tokens is not None:
        result['teacherTokens'] = list(teacher_tokens)
    require(len(canonical(result)) <= limits['maxLineBytes'], 'Request exceeds native line limit')
    return result


def completed(value, command, ready_record, rank, tokens):
    frame(value, 'completed', command['epoch'], rank, command['sequence'], command, ready_record['modelLoadID'])
    result = value['result']
    need(isinstance(result, dict) and RESULT_KEYS <= set(result) <= RESULT_KEYS | {'decodeTokensPerSecond'},
         'Completed result has missing or unknown fields')
    work = dict(prompt_tokens=len(command['prompt']), decode_tokens=command['outputTokens'])
    if 'teacherTokens' in command:
        work['teacher_tokens'] = command['teacherTokens']
    try:
        validate_run(result, work, command['sequence'], ready_record['identity']['vocabularySize'],
                     ready_record['identity']['tokenSelectionPolicy'], rank)
    except ValueError as error:
        raise PersistentCohortError(str(error)) from error
    same(result['generatedTokens'], tokens, 'completed generatedTokens')
    need(('logits' in value) == command['captureLogits'], 'Completed capture policy differs')
    if command['captureLogits']:
        import math
        logits, vocabulary = value['logits'], ready_record['identity']['vocabularySize']
        need(isinstance(logits, list) and len(logits) == command['outputTokens'], 'Completed logit row count differs')
        for row in logits:
            need(isinstance(row, list) and len(row) == vocabulary and
                 all(type(x) in (int, float) and math.isfinite(x) for x in row), 'Completed logits contain invalid values or shape')
        local = [max(range(vocabulary), key=row.__getitem__) for row in logits]
        same(result['localArgmaxTokens'], local, 'captured local argmax')
    return value
