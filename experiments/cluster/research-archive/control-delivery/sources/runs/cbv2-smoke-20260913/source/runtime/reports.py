"""Validate complete Swift Report/RunResult records before accepting a cohort."""

import datetime
import hashlib
import json
import math
from pathlib import Path
import re

from .model_profiles import MODEL_FAMILIES, synthetic_identity
from .partition_storage import SOURCE_FIELDS, validate_storage


FLOAT_DTYPES = {'float16', 'bfloat16', 'float32'}
FINGERPRINTS = ('configurationSHA256', 'promptSHA256', 'parameterLayoutSHA256')


def invalid(field, reason):
    raise ValueError(f'Invalid native report {field}: {reason}')


def equal(record, field, expected):
    value = record.get(field)
    if type(value) is not type(expected) or value != expected:
        invalid(field, f'expected {expected!r}')


def integer(record, field, minimum=0):
    value = record.get(field)
    if type(value) is not int or not minimum <= value <= 2**63 - 1:
        invalid(field, f'expected an integer >= {minimum}')
    return value


def number(record, field, positive=False):
    value = record.get(field)
    try:
        finite = type(value) in (int, float) and math.isfinite(value)
    except OverflowError:
        finite = False
    if not finite or value < 0 or (positive and value == 0):
        invalid(field, 'expected a finite positive number' if positive else 'expected a finite nonnegative number')
    return value


def fingerprint(record, field):
    value = record.get(field)
    if not isinstance(value, str) or not re.fullmatch(r'[0-9a-f]{64}', value):
        invalid(field, 'expected a lowercase SHA-256')
    return value


def close(actual, expected, field):
    if not math.isclose(actual, expected, rel_tol=1e-9, abs_tol=1e-9):
        invalid(field, 'does not agree with the measured counts/times')


def validate_run(run, workload, iteration, vocabulary, policy, rank):
    if not isinstance(run, dict):
        invalid('runs', 'each run must be an object')
    equal(run, 'iteration', iteration)
    equal(run, 'promptTokens', workload['prompt_tokens'])
    forwards = workload['decode_tokens'] - 1
    equal(run, 'decodeForwardCount', forwards)
    tokens = run.get('generatedTokens')
    if (not isinstance(tokens, list) or len(tokens) != workload['decode_tokens']
            or any(type(token) is not int or not 0 <= token < vocabulary for token in tokens)):
        invalid('generatedTokens', 'expected every requested output token ID')
    local = run.get('localArgmaxTokens')
    if (not isinstance(local, list) or len(local) != len(tokens)
            or any(type(token) is not int or not 0 <= token < vocabulary for token in local)):
        invalid('localArgmaxTokens', 'expected every local argmax within the vocabulary')
    equal(run, 'localArgmaxDisagreementCount', sum(a != b for a, b in zip(local, tokens)))
    if (policy == 'local-greedy' or rank == 0) and local != tokens:
        invalid('generatedTokens', 'must equal the selecting rank\'s local argmax')
    inputs = workload.get('teacher_tokens')
    if inputs is None:
        inputs = tokens[:-1]
    actual_inputs = run.get('decodeInputTokens')
    if (not isinstance(actual_inputs, list)
            or any(type(token) is not int or not 0 <= token < vocabulary for token in actual_inputs)
            or actual_inputs != inputs):
        invalid('decodeInputTokens', 'must consume the teacher history or previously selected output tokens')
    prefill = number(run, 'prefillSeconds', positive=True)
    prefill_tps = number(run, 'prefillTokensPerSecond', positive=True)
    close(prefill_tps, workload['prompt_tokens'] / prefill, 'prefillTokensPerSecond')
    steps = run.get('decodeStepSeconds')
    if not isinstance(steps, list) or len(steps) != forwards:
        invalid('decodeStepSeconds', 'expected one timing per decode forward')
    for value in steps:
        number({'step': value}, 'step', positive=True)
    elapsed = number(run, 'decodeSeconds')
    close(elapsed, math.fsum(steps), 'decodeSeconds')
    if forwards:
        if elapsed == 0:
            invalid('decodeSeconds', 'decode forwards require positive elapsed time')
        tps = number(run, 'decodeTokensPerSecond', positive=True)
        close(tps, forwards / elapsed, 'decodeTokensPerSecond')
    elif elapsed != 0 or run.get('decodeTokensPerSecond') is not None:
        invalid('decodeTokensPerSecond', 'no-forward decode has zero time and no TPS')
    peak, active = integer(run, 'peakMLXBytes'), integer(run, 'activeMLXBytes')
    if active > peak:
        invalid('peakMLXBytes', 'cannot be smaller than active memory')


def validate_receipt(record, spec, rank, required):
    receipt = record.get('directShardLoad')
    if not required:
        if receipt is not None:
            invalid('directShardLoad', 'unexpected direct-shard receipt')
        return
    if not isinstance(receipt, dict):
        invalid('directShardLoad', 'real cooperative runs require a verified load receipt')
    fingerprint(receipt, 'verifiedAggregateSHA256')
    equal(receipt, 'verifiedAggregateSHA256', spec['artifact_aggregate_sha256'])
    equal(receipt, 'rank', rank)
    for field in SOURCE_FIELDS:
        integer(receipt, field, 1)
    loaded = integer(receipt, 'loadedTensorBytes', 1)
    largest = integer(receipt, 'largestHostTensorBytes', 1)
    tensor_count = integer(receipt, 'tensorCount', 1)
    source_count = integer(receipt, 'sourceTensorCount', 1)
    storage = record['partitionStorage']
    validate_storage(receipt.get('partitionStorage'), spec['partition'], rank, record['parameterLayoutSHA256'])
    if receipt.get('partitionStorage') != storage:
        invalid('directShardLoad.partitionStorage', 'must equal the report storage commitment')
    for field in SOURCE_FIELDS:
        equal(receipt, field, storage[field])
    # Checkpoint copy accounting, before dtype conversion; each rank's owned
    # selected bytes are bound by the shared plan, including unequal intervals.
    if (loaded != storage['ranks'][rank]['loadedTensorBytes']
            or largest > loaded or source_count < tensor_count):
        invalid('directShardLoad', 'inconsistent two-rank tensor byte accounting')


def validate_report(record, spec, rank):
    """Validate against an already validated run spec; this does not certify solo/TP parity."""
    if not isinstance(record, dict):
        invalid('record', 'expected an object')
    for field in ('routingTraceEnabled', 'routingReplayEnabled',
                  'gemmaDiagnosticScheduleEnabled', 'gemmaBoundaryTraceEnabled'):
        if field in record:
            invalid(field, 'diagnostics cannot serve as benchmark reports')
    workload = spec['workload']
    cooperative = spec['backend'] in ('jaccl', 'loopback-test')
    synthetic = workload.get('synthetic', False)
    loopback = spec['backend'] == 'loopback-test'
    for field, expected in {
        'schemaVersion': 8,
        'mode': 'ffn-tp' if cooperative else 'baseline',
        'partition': spec['partition'] if cooperative else 'none',
        'worldSize': 2 if cooperative else 1,
        'rank': rank if cooperative else 0,
        'promptSource': 'token-file' if 'prompt_ids' in workload else 'synthetic-token-ids',
        'teacherForced': workload.get('teacher_tokens') is not None,
        'tokenSelectionPolicy': 'rank0-greedy' if cooperative else 'local-greedy',
        'chunkSize': workload['chunk_size'],
        'seed': workload['seed'],
        'attentionOutputPrecision': workload['attention_output_precision'],
        'ffnBranchPrecision': workload['ffn_branch_precision'],
        'executionPath': workload['execution_path'],
        'syntheticWeights': synthetic,
        'mtpEnabled': False,
        'bf16ConversionEnabled': not synthetic,
        'transport': spec['backend'] if cooperative else 'none',
        'correctnessOnly': loopback,
        'throughputMeasurementValid': not loopback and not (cooperative and spec['capture_logits']),
        'decodeScheduling': 'synchronous-per-token',
        'prefillDefinition': 'all prompt tokens through first generated token',
    }.items():
        equal(record, field, expected)
    if not isinstance(record.get('model'), str) or not record['model'].strip():
        invalid('model', 'expected a nonempty model label')
    if synthetic:
        for field, expected in synthetic_identity(workload).items():
            if field != 'layerCount':  # Reports expose shardedFFNs; ready exposes layerCount.
                equal(record, field, expected)
        equal(record, 'syntheticDType', workload['synthetic_dtype'])
        equal(record, 'syntheticProfile', workload['synthetic_profile'])
        equal(record, 'embeddingActivationDType', workload['synthetic_dtype'])
        equal(record, 'ffnScaleDTypes', [workload['synthetic_dtype']])
    else:
        for field in ('syntheticDType', 'syntheticProfile'):
            if field in record:
                invalid(field, 'real-model reports must omit synthetic fixture options')
    if record.get('feedForwardKind') not in ('dense', 'moe'):
        invalid('feedForwardKind', 'expected dense or moe')
    family = record.get('modelFamily')
    if family not in MODEL_FAMILIES:
        invalid('modelFamily', 'expected qwen35 or gemma4')
    if family == 'gemma4' and (record['partition'] == 'full' or record['attentionOutputPrecision'] != 'native'):
        invalid('modelFamily', 'Gemma supports FFN partitioning and native attention precision only')
    if family != 'gemma4' and record['ffnBranchPrecision'] != 'native':
        invalid('ffnBranchPrecision', 'Float32 FFN branch precision requires a Gemma model')
    if record['executionPath'] == 'cbv2-contiguous' and (family != 'qwen35' or record['feedForwardKind'] != 'dense'):
        invalid('executionPath', 'CBv2 contiguous execution currently requires a dense Qwen model')
    vocabulary = integer(record, 'vocabularySize', 4)
    if vocabulary > (2**31 - 1) // 2:
        invalid('vocabularySize', 'exceeds the token-selection protocol limit')
    for field in FINGERPRINTS:
        fingerprint(record, field)
    if cooperative:
        fingerprint(record, 'partitionPlanSHA256')
        validate_storage(record.get('partitionStorage'), spec['partition'], rank, record['parameterLayoutSHA256'])
    elif 'partitionPlanSHA256' in record:
        invalid('partitionPlanSHA256', 'baseline must omit the partition plan')
    elif 'partitionStorage' in record:
        invalid('partitionStorage', 'baseline must omit the storage commitment')
    if 'prompt_ids' in workload:
        encoded = json.dumps(workload['prompt_ids'], separators=(',', ':')).encode()
        equal(record, 'promptSHA256', hashlib.sha256(encoded).hexdigest())
    teacher = workload.get('teacher_tokens')
    if teacher is not None:
        encoded = json.dumps(teacher, separators=(',', ':')).encode()
        equal(record, 'teacherSHA256', hashlib.sha256(encoded).hexdigest())
    elif record.get('teacherSHA256') is not None:
        invalid('teacherSHA256', 'unexpected teacher-forced input fingerprint')
    sharded = integer(record, 'shardedFFNs', 1 if cooperative else 0)
    if not cooperative and sharded != 0:
        invalid('shardedFFNs', 'baseline must not shard any FFN')
    activation = record.get('embeddingActivationDType')
    if not isinstance(activation, str) or activation not in FLOAT_DTYPES:
        invalid('embeddingActivationDType', 'unsupported activation dtype')
    scales = record.get('ffnScaleDTypes')
    if (not isinstance(scales, list) or not scales
            or any(not isinstance(dtype, str) or dtype not in FLOAT_DTYPES for dtype in scales)
            or len(set(scales)) != len(scales)):
        invalid('ffnScaleDTypes', 'expected distinct supported scale dtypes')
    number(record, 'loadSeconds')
    timestamp = record.get('timestamp')
    try:
        parsed = datetime.datetime.fromisoformat(timestamp.replace('Z', '+00:00'))
        if parsed.utcoffset() is None:
            raise ValueError('missing timezone')
    except (AttributeError, TypeError, ValueError):
        invalid('timestamp', 'expected an ISO timestamp with timezone')
    runs = record.get('runs')
    if not isinstance(runs, list) or len(runs) != workload['repeats']:
        invalid('runs', 'expected every requested measured repetition')
    for iteration, run in enumerate(runs):
        validate_run(run, workload, iteration, vocabulary, record['tokenSelectionPolicy'], record['rank'])
    validate_receipt(record, spec, rank, required=cooperative and not synthetic)
    return record


def json_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            invalid('JSON', f'duplicate field {key}')
        result[key] = value
    return result


def read_report(path):
    records = []
    for line in path.read_text().splitlines():
        if not line.strip():
            continue
        try:
            records.append(json.loads(line, object_pairs_hook=json_object,
                                      parse_constant=lambda value: invalid('JSON', f'nonfinite {value}')))
        except json.JSONDecodeError:
            if line.lstrip().startswith(('{', '[')):
                invalid('JSON', 'malformed report output')
            # Native/library diagnostics may be plain text; they cannot serve as reports.
    if len(records) != 1:
        invalid('record count', 'expected exactly one complete native report')
    return records[0]


def reports(ranks, spec):
    if not isinstance(ranks, list) or len(ranks) != len(spec['ranks']):
        invalid('cohort', 'missing rank results')
    if any(not isinstance(rank, dict) or type(rank.get('rank')) is not int for rank in ranks):
        invalid('cohort', 'malformed rank descriptor')
    if sorted(rank['rank'] for rank in ranks) != list(range(len(ranks))):
        invalid('cohort', 'rank results must cover each rank exactly once')
    output = [validate_report(read_report(Path(rank['local']) / 'stdout.jsonl'), spec, rank['rank'])
              for rank in sorted(ranks, key=lambda item: item['rank'])]
    cooperative = spec['backend'] in ('jaccl', 'loopback-test')
    shared = ('configurationSHA256', 'promptSHA256', 'teacherSHA256', 'bf16ConversionEnabled',
              'embeddingActivationDType', 'ffnScaleDTypes', 'shardedFFNs',
              'partition', 'partitionPlanSHA256', 'tokenSelectionPolicy', 'syntheticDType',
              'syntheticProfile', 'feedForwardKind', 'vocabularySize', 'attentionOutputPrecision',
              'modelFamily', 'model', 'partitionStorage', 'ffnBranchPrecision', 'executionPath')
    if not cooperative:
        shared += ('parameterLayoutSHA256',)
    for field in shared:
        if any(record.get(field) != output[0].get(field) for record in output[1:]):
            invalid(field, 'rank reports disagree')
    if cooperative:
        for index in range(spec['workload']['repeats']):
            if any(record['runs'][index]['generatedTokens'] != output[0]['runs'][index]['generatedTokens']
                   for record in output[1:]):
                invalid('generatedTokens', 'cooperative ranks disagree')
        if output[0].get('directShardLoad'):
            for field in ('sourceModelTensorBytes', 'sourceFFNTensorBytes', 'sourceShardedFFNTensorBytes',
                          'sourceShardedTensorBytes', 'sourceTensorCount', 'tensorCount'):
                if any(record['directShardLoad'][field] != output[0]['directShardLoad'][field]
                       for record in output[1:]):
                    invalid('directShardLoad.' + field, 'rank receipts disagree')
    return output
