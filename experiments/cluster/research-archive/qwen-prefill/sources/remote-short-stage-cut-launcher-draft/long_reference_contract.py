"""Bounded short cut12 outer records only; independent numerical audit stays separate."""
import json
import math
from pathlib import Path
from long_reference_inputs import ARTIFACT, CONFIGURATION, is_sha256, require
from short_cut_request import equal, validate_request, expected_source
from short_cut_expected import (PLAN_SHA256, SOURCE_LAYOUT_SHA256, SOURCE_MODEL_BYTES, STAGE_PLAN_SHA256,
                                STAGE_CONFIGURATION_SHA256, NAMED_STATE_AND_BOUNDARY_BYTES)

FIRST, FINAL = 'qwen_layer_stage_baseline_checkpoint', 'qwen_layer_stage_comparison_report'
MAX_STDOUT, MAX_STDERR, MAX_LINE = 64 * 1024**2, 64 * 1024, 60 * 1024**2


def parse(data):
    def pairs(values):
        result = {}
        for key, value in values:
            require(key not in result, 'Duplicate JSON key')
            result[key] = value
        return result
    def number(value):
        result = float(value)
        require(math.isfinite(result), 'Nonfinite JSON number')
        return result
    def invalid(value):
        raise ValueError('Nonfinite JSON constant')
    return json.loads(data, object_pairs_hook=pairs, parse_float=number, parse_constant=invalid,
                      parse_int=lambda value: -0.0 if value == '-0' else int(value))


def flags(record, **expected):
    for key, value in expected.items():
        require(type(record.get(key)) is bool and record[key] is value, 'Wrong flag: ' + key)


def memory_records(values, phases):
    require(type(values) is list and len(values) == len(phases), 'Wrong native memory phase count')
    for value, phase in zip(values, phases):
        require(type(value) is dict and set(value) == {'phase', 'activeMLXBytes', 'cachedMLXBytes', 'peakMLXBytesSinceProcessStart'}
                and value['phase'] == phase, 'Wrong native memory phase')
        require(all(type(value[key]) is int and value[key] >= 0
                    for key in ('activeMLXBytes', 'cachedMLXBytes', 'peakMLXBytesSinceProcessStart')),
                'Invalid native memory counter')


def validate_first(record, inputs):
    require(type(record) is dict and set(record) == {'kind', 'baselineModelReleasedBeforeStageLoading', 'baseline', 'memory'}
            and record['kind'] == FIRST, 'Expected the exact completed baseline checkpoint first')
    flags(record, baselineModelReleasedBeforeStageLoading=True)
    baseline = record['baseline']
    require(type(baseline) is dict and set(baseline) == {'kind', 'correctnessOnly', 'throughputMeasurementValid',
            'request', 'source', 'frames', 'fingerprint', 'allRequestStateRetired'}
            and baseline['kind'] == 'qwen_layer_stage_recorded_baseline', 'Wrong recorded baseline namespace')
    flags(baseline, correctnessOnly=True, throughputMeasurementValid=False, allRequestStateRetired=True)
    validate_request(baseline['request'], inputs)
    equal(baseline['source'], expected_source(), 'Wrong baseline artifact/configuration/cut-plan identity')
    require(is_sha256(baseline['fingerprint']) and type(baseline['frames']) is list and len(baseline['frames']) == 6,
            'Missing bounded baseline evidence')
    memory_records(record['memory'], ['before_baseline_load', 'baseline_released_cache_cleared'])


def validate_final(record, first, inputs):
    require(type(record) is dict and set(record) == {'kind', 'correctnessOnly', 'throughputMeasurementValid',
            'baselineModelReleasedBeforeStageLoading', 'stageModelsReleasedAfterComparison',
            'conservativeStateAndBoundaryBytes', 'stageLoads', 'comparison', 'memory'}
            and record['kind'] == FINAL, 'Wrong short comparison terminal namespace')
    flags(record, correctnessOnly=True, throughputMeasurementValid=False,
          baselineModelReleasedBeforeStageLoading=True, stageModelsReleasedAfterComparison=True)
    require(type(record['conservativeStateAndBoundaryBytes']) is int
            and record['conservativeStateAndBoundaryBytes'] == NAMED_STATE_AND_BOUNDARY_BYTES,
            'Wrong unchanged named-state/boundary estimate')
    baseline, compared = first['baseline'], record['comparison']
    require(type(compared) is dict and set(compared) == {'kind', 'correctnessOnly', 'throughputMeasurementValid',
            'sequentialOneProcessOnly', 'nativeBoundaryBytesCopied', 'baselineEvidenceSHA256', 'requestSHA256',
            'source', 'stageStorageCommitmentSHA256', 'frames', 'allRequestStateRetired'}
            and compared['kind'] == 'qwen_layer_stage_recorded_comparison', 'Wrong inner comparison namespace')
    flags(compared, correctnessOnly=True, throughputMeasurementValid=False,
          sequentialOneProcessOnly=True, nativeBoundaryBytesCopied=True, allRequestStateRetired=True)
    require(compared['baselineEvidenceSHA256'] == baseline['fingerprint']
            and compared['requestSHA256'] == baseline['request']['fingerprint']
            and is_sha256(compared['stageStorageCommitmentSHA256'])
            and type(compared['frames']) is list and len(compared['frames']) == 6,
            'Comparison is not bound to the completed baseline/request')
    equal(compared['source'], baseline['source'], 'Comparison source differs from the completed baseline')
    loads = record['stageLoads']
    require(type(loads) is list and len(loads) == 2, 'Expected two loaded stage receipts')
    for index, receipt in enumerate(loads):
        require(type(receipt) is dict and type(receipt.get('schemaVersion')) is int and receipt['schemaVersion'] == 1
                and type(receipt.get('stageIndex')) is int and receipt['stageIndex'] == index,
                'Wrong ordered stage-load identity')
        flags(receipt, bf16ConversionEnabled=True)
        for key, expected in [('verifiedAggregateSHA256', ARTIFACT), ('sourceConfigurationSHA256', CONFIGURATION),
            ('sourceParameterLayoutSHA256', SOURCE_LAYOUT_SHA256), ('sourceModelTensorBytes', SOURCE_MODEL_BYTES),
            ('planSHA256', PLAN_SHA256), ('stagePlanSHA256', STAGE_PLAN_SHA256[index]),
            ('constructionConfigurationSHA256', STAGE_CONFIGURATION_SHA256[index]),
            ('embeddingActivationDType', 'bfloat16'), ('storageCommitmentSHA256', compared['stageStorageCommitmentSHA256'])]:
            equal(receipt.get(key), expected, 'Wrong source or explicit cut stage identity: ' + key)
    memory_records(record['memory'], ['before_baseline_load', 'baseline_released_cache_cleared',
        'both_stages_loaded', 'stage_requests_retired', 'stage_models_released_cache_cleared'])
    equal(record['memory'][:2], first['memory'], 'Baseline memory prefix changed')
    # No state/logit arithmetic, row-byte equality or nested fingerprint replay
    # is claimed here. Those require the separately frozen numerical auditor.


class Records:
    def __init__(self, directory, inputs):
        self.directory, self.inputs = Path(directory), inputs
        self.offset, self.pending, self.rows = 0, b'', []

    def poll(self, final=False):
        err = self.directory / 'stderr.log'
        error_size = err.stat().st_size if err.exists() else 0
        require(error_size <= MAX_STDERR, 'stderr exceeds 64 KiB')
        require(error_size == 0, 'Short comparison emitted stderr')
        path = self.directory / 'stdout.jsonl'
        size = path.stat().st_size if path.exists() else 0
        require(self.offset <= size <= MAX_STDOUT, 'stdout shrank or exceeded 64 MiB')
        if size > self.offset:
            with path.open('rb') as stream:
                stream.seek(self.offset)
                chunk = stream.read(MAX_STDOUT - self.offset + 1)
            self.offset += len(chunk)
            self.pending += chunk
            require(self.offset <= MAX_STDOUT, 'stdout grew beyond its bound')
        while b'\n' in self.pending:
            raw, self.pending = self.pending.split(b'\n', 1)
            require(raw and len(raw) <= MAX_LINE and len(self.rows) < 2, 'Invalid record size/count')
            value = parse(raw)
            require(type(value) is dict, 'Record must be an object')
            if not self.rows:
                validate_first(value, self.inputs)
            else:
                validate_final(value, self.rows[0], self.inputs)
            self.rows.append(value)
        require(len(self.pending) <= MAX_LINE, 'Partial record exceeds line bound')
        if final:
            require(not self.pending and len(self.rows) == 2, 'EOF without both complete records')
