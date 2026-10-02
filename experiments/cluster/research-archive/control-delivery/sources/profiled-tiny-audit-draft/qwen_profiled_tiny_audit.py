"""Prospective CPU oracle for the fixed nine-record profiled tiny check.

Reads saved output only when explicitly invoked. No native/library/process import.
"""
import argparse
import json
import math
from pathlib import Path
from profiled_tiny_expected import (DEFAULT_BINDINGS, ENVIRONMENT, PROFILE, canonical, exact,
    fingerprint, frames, integer, native_logit_bytes, prompt, recorded_fingerprint, require, sha,
    state_bytes, validate_spec)
from profiled_tiny_loader_audit import validate_loader


def read_records(path):
    with Path(path).open('rb') as stream: raw = stream.read(8 * 1024**2 + 1)
    require(0 < len(raw) <= 8 * 1024**2 and raw.endswith(b'\n'), 'Output must be bounded complete JSONL')
    def unique(pairs):
        value = {}
        for key, item in pairs:
            require(key not in value, 'Duplicate native JSON key'); value[key] = item
        return value
    def floating(raw):
        value = float(raw); require(math.isfinite(value), 'Nonfinite JSON float'); return value
    def invalid(_): raise ValueError('Nonfinite JSON constant')
    lines = raw.splitlines(); require(len(lines) == 9 and all(lines), 'Expected exactly nine nonempty native records')
    rows = [json.loads(line, object_pairs_hook=unique, parse_float=floating, parse_constant=invalid,
        parse_int=lambda raw: -0.0 if raw == '-0' else int(raw)) for line in lines]
    require(all(type(row) is dict for row in rows), 'Native records must be objects')
    return rows, sha(raw)


def validate_environment(record):
    expected = dict(kind='qwen_layer_stage_profiled_fixture_environment', correctnessOnly=True,
        profile=PROFILE, promptCounts=[1025, 8192], chunkSize=512, outputCount=1,
        syntheticDTypes=['float32', 'bfloat16'], throughputMeasurementValid=False,
        arithmeticEnvironment=dict(contract='qwen_cbv2_query128_bf16_tf32_default_v1', requiredValues=ENVIRONMENT,
            requiredAbsentNames=['MLX_METAL_GPU_ARCH', 'MLX_SDPA_BLOCKS'], full512TokenChunkQueryBlocks=4,
            defaultBindings=DEFAULT_BINDINGS, actualProcessEnvironmentMustBePassedBeforeMLXInitialization=True,
            sourceBinaryMetalLibraryAndHardwareIdentityStillRequired=True, sameChunkFullModelReferenceStillRequired=True,
            doesNotValidateOtherTimingOrResourceEnvironment=True, numericalOrPerformanceQualificationEstablished=False))
    exact(record, expected, 'Source-bound arithmetic environment/profile matrix differs')


def validate_lifecycle(record, seen_ids):
    require(set(record) == {'kind', 'correctnessOnly', 'throughputMeasurementValid', 'request',
        'faultInjectedAfterFirstStageCommit', 'failedStageFrontiers', 'bothRequestsFailedAndRetired',
        'retiredRequestReuseRejected'}, 'Unexpected lifecycle fields')
    expected = dict(kind='qwen_layer_stage_profiled_lifecycle_check', correctnessOnly=True,
        throughputMeasurementValid=False, faultInjectedAfterFirstStageCommit=True,
        failedStageFrontiers=[512, 0], bothRequestsFailedAndRetired=True, retiredRequestReuseRejected=2)
    exact({key: value for key, value in record.items() if key != 'request'}, expected, 'Lifecycle fault/retirement differs')
    validate_spec(record['request'], 1025, seen_ids)


def validate_request(record, count, seen_ids):
    require(type(record) is dict and set(record) == {'request', 'vocabularySize', 'promptTokenIDs',
        'teacherTokenIDs', 'steps', 'fingerprint'}, 'Unexpected recorded request fields')
    validate_spec(record['request'], count, seen_ids)
    tokens = prompt(count)
    expected = dict(request=record['request'], vocabularySize=512, promptTokenIDs=tokens,
        teacherTokenIDs=[], fingerprint=recorded_fingerprint(record['request']),
        steps=[dict(frame=frame, tokenIDs=tokens[frame['tokenOffset']:frame['tokenOffset'] + frame['tokenCount']],
            committedTokens=frame['tokenOffset'] + frame['tokenCount']) for frame in frames(count)])
    exact(record, expected, 'Recorded prompt, teacher policy, schedule or fingerprint differs')


def validate_parity(record, dtype, count, source, seen_ids):
    require(set(record) == {'kind', 'correctnessOnly', 'throughputMeasurementValid', 'interprocessTransportUsed',
        'syntheticDType', 'sourceConfigurationSHA256', 'artifactAggregateSHA256', 'planSHA256', 'request',
        'frames', 'baselineSelectedToken', 'stageSelectedToken', 'allRequestsRetired',
        'sourceFilesDeletedBeforeForward', 'nativeBoundaryBytesCopied'}, 'Unexpected parity fields')
    for key, value in dict(kind='qwen_layer_stage_profiled_parity_check', correctnessOnly=True,
        throughputMeasurementValid=False, interprocessTransportUsed=False, syntheticDType=dtype,
        allRequestsRetired=True, sourceFilesDeletedBeforeForward=True, nativeBoundaryBytesCopied=True,
        sourceConfigurationSHA256=source['configuration'], artifactAggregateSHA256=source['artifact'],
        planSHA256=source['plan']).items(): exact(record.get(key), value, 'Parity identity/scope differs: ' + key)
    validate_request(record['request'], count, seen_ids)
    timeline = frames(count); native = record.get('frames')
    require(type(native) is list and len(native) == len(timeline), 'Missing committed frame evidence')
    final_values = None
    for index, (frame, expected) in enumerate(zip(native, timeline)):
        final = index == len(timeline) - 1
        keys = {'phase', 'committedTokens', 'stateEntriesCompared', 'stateBytesCompared', 'fullStateSHA256', 'stateShapesDTypesAndBytesExact'}
        if final: keys |= {'logits', 'logitsBytesExact'}
        require(type(frame) is dict and set(frame) == keys, 'Unexpected frame evidence/capture fields')
        frontier = expected['tokenOffset'] + expected['tokenCount']
        for key, value in dict(phase='prefill', committedTokens=frontier, stateEntriesCompared=18,
            stateBytesCompared=state_bytes(dtype, frontier), stateShapesDTypesAndBytesExact=True).items():
            exact(frame.get(key), value, 'Frame state geometry/frontier differs: ' + key)
        fingerprint(frame['fullStateSHA256'], 'Malformed complete state fingerprint')
        if final:
            exact(frame.get('logitsBytesExact'), True, 'Final native byte equality assertion missing')
            logits = frame.get('logits')
            require(type(logits) is dict and set(logits) == {'shape', 'dtype', 'logicalBytesSHA256', 'values'}, 'Final logit receipt fields differ')
            exact(logits['shape'], [1, 512], 'Final full-vocabulary shape differs')
            exact(logits['dtype'], dtype, 'Final native logit dtype differs')
            native_bytes = native_logit_bytes(logits['values'], dtype)
            exact(sha(native_bytes), logits['logicalBytesSHA256'], 'Exported values do not reproduce native logical logit SHA')
            final_values = logits['values']
    # Pinned Metal ArgMax.reduce chooses the lower index for equal maxima.
    maximum = max(final_values); token = next(i for i, value in enumerate(final_values) if value == maximum)
    exact(record.get('baselineSelectedToken'), token, 'Baseline finite first-index argmax differs')
    exact(record.get('stageSelectedToken'), token, 'Stage finite first-index argmax differs')
    return dict(dtype=dtype, promptCount=count, chunkSize=512, frames=len(timeline), stateEntriesPerFrame=18,
        finalStateBytes=state_bytes(dtype, count), fullLogitValues=512, selectedToken=token,
        maximumTieCount=sum(value == maximum for value in final_values), sourceConfigurationSHA256=source['configuration'])


def validate_rows(rows):
    require(type(rows) is list and len(rows) == 9, 'Expected environment plus two four-record fixture cohorts')
    validate_environment(rows[0]); summaries = []; seen_ids = set()
    for index, dtype in enumerate(('float32', 'bfloat16')):
        loader, lifecycle, short, long = rows[1 + 4 * index:5 + 4 * index]
        source = validate_loader(loader, dtype)
        validate_lifecycle(lifecycle, seen_ids)
        summaries.extend(validate_parity(record, dtype, count, source, seen_ids)
            for record, count in ((short, 1025), (long, 8192)))
    require(len(seen_ids) == 6, 'Request retirement matrix reused identities')
    return dict(kind='qwen_profiled_tiny_cpu_audit', passed=True, cpuOnly=True,
        nativeRecords=9, requests=6, parityFrames=38, fullLogitRows=4, fixtures=summaries,
        contextTokens=8193, profile=PROFILE, throughputQualified=False, physicalTransportQualified=False,
        stateEqualityIsNativeByteComparisonAssertion=True, exportedLogitHashesIndependentlyReproduced=True)


def validate(path):
    rows, output_sha = read_records(path)
    result = validate_rows(rows); result['nativeOutputSHA256'] = output_sha
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__); parser.add_argument('stdout', type=Path)
    args = parser.parse_args(); print(json.dumps(validate(args.stdout), sort_keys=True, allow_nan=False))


if __name__ == '__main__': main()
