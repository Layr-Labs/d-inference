"""Bounded outer records only; the independent oracle audits producer evidence."""
import json
import math
from pathlib import Path
from long_reference_inputs import ARTIFACT, CONFIGURATION, PROFILE, PROFILE_SHA256, is_sha256, require
from long_pair_cut import validate_reference_source, validate_selected_stages

FIRST, FINAL = 'qwen_long_prefill_pair_reference_checkpoint', 'qwen_long_prefill_pair_report'
MAX_STDOUT, MAX_STDERR, MAX_LINE = 8 * 1024**2, 64 * 1024, 8 * 1024**2


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


def validate_first(record, inputs):
    keys = {'kind', 'schemaVersion', 'baselineModelReleasedBeforeStageLoading', 'reference', 'memory'}
    require(set(record) == keys and record['kind'] == FIRST
            and type(record['schemaVersion']) is int and record['schemaVersion'] == 1,
            'Expected exact completed full-reference checkpoint first')
    flags(record, baselineModelReleasedBeforeStageLoading=True)
    reference = record['reference']
    require(type(reference) is dict and reference.get('kind') == 'qwen_registered9b_long_prefill_reference',
            'Missing complete long reference')
    flags(reference, correctnessOnly=True, throughputMeasurementValid=False,
          modelReleased=True, allRequestStateRetired=True)
    require(reference.get('profile') == PROFILE and reference.get('profileFingerprint') == PROFILE_SHA256
            and reference.get('promptFileSHA256') == inputs['prompt_file_sha256']
            and reference.get('promptTokenIDsSHA256') == inputs['prompt_token_ids_sha256']
            and is_sha256(reference.get('arithmeticEnvironmentSHA256'))
            and is_sha256(reference.get('fingerprint')), 'Reference input/profile identity differs')
    source = reference.get('execution', {}).get('source', {})
    require(source.get('artifactAggregateSHA256') == ARTIFACT
            and source.get('sourceConfigurationSHA256') == CONFIGURATION, 'Wrong complete reference source')
    validate_reference_source(source)
    memory_phases(record['memory'], ['before_baseline_load', 'baseline_released_cache_cleared'])


def validate_final(record, first, inputs):
    keys = {'kind', 'schemaVersion', 'correctnessOnly', 'throughputMeasurementValid',
            'interprocessTransportUsed', 'physicalTransferQualified', 'allRequestStateRetired',
            'baselineModelReleasedBeforeStageLoading', 'stageModelsReleased', 'stageLoads', 'comparison', 'memory'}
    require(set(record) == keys and record['kind'] == FINAL
            and type(record['schemaVersion']) is int and record['schemaVersion'] == 1,
            'Wrong terminal namespace/schema or unexpected timing field')
    flags(record, correctnessOnly=True, throughputMeasurementValid=False,
          interprocessTransportUsed=False, physicalTransferQualified=False,
          allRequestStateRetired=True, baselineModelReleasedBeforeStageLoading=True, stageModelsReleased=True)
    comparison = record['comparison']
    require(type(comparison) is dict and comparison.get('kind') == 'qwen_long_prefill_pair_comparison'
            and comparison.get('baselineEvidenceFingerprint') == first['reference']['fingerprint'],
            'Pair comparison lost its complete reference identity')
    flags(comparison, correctnessOnly=True, throughputMeasurementValid=False,
          interprocessTransportUsed=False, physicalTransferQualified=False, allRequestStateRetired=True,
          completeStateMetadataAndDigestsExact=True, finalLogitMetadataAndDigestExact=True,
          selectedTokenExact=True, candidateFullLogitValuesExported=False, candidateNativeBytesComparedDirectly=False)
    require(type(comparison.get('frames')) is list and len(comparison['frames']) == 16
            and type(comparison.get('finalDigests')) is list and len(comparison['finalDigests']) == 2,
            'Pair omitted native frames or final stage digests')
    stages = record['stageLoads']
    require(type(stages) is list and len(stages) == 2 and [x.get('stageIndex') for x in stages] == [0, 1],
            'Pair omitted loaded stages')
    for stage in stages:
        require(stage.get('verifiedAggregateSHA256') == ARTIFACT
                and stage.get('sourceConfigurationSHA256') == CONFIGURATION, 'Pair stage source differs')
    validate_selected_stages(stages, comparison.get('agreement'))
    memory_phases(record['memory'], ['before_baseline_load', 'baseline_released_cache_cleared',
        'both_stages_loaded', 'stage_requests_retired_weights_resident', 'stage_models_released_cache_cleared'])
    require(record['memory'][:2] == first['memory'], 'Pair changed baseline memory observations')


def memory_phases(memory, phases):
    require(type(memory) is list and len(memory) == len(phases), 'Missing native memory phases')
    for value, phase in zip(memory, phases):
        require(type(value) is dict and set(value) == {'phase', 'activeMLXBytes', 'cachedMLXBytes', 'peakMLXBytesSinceProcessStart'}
                and value['phase'] == phase, 'Wrong native memory observation')
        require(all(type(value[key]) is int and value[key] >= 0
                    for key in ('activeMLXBytes', 'cachedMLXBytes', 'peakMLXBytesSinceProcessStart')),
                'Invalid native memory counters')


class Records:
    def __init__(self, directory, inputs):
        self.directory, self.inputs = Path(directory), inputs
        self.offset, self.pending, self.rows = 0, b'', []

    def poll(self, final=False):
        err = self.directory / 'stderr.log'
        error_size = err.stat().st_size if err.exists() else 0
        require(error_size <= MAX_STDERR, 'stderr exceeds 64 KiB')
        require(error_size == 0, 'Reference process emitted stderr')
        path = self.directory / 'stdout.jsonl'
        size = path.stat().st_size if path.exists() else 0
        require(self.offset <= size <= MAX_STDOUT, 'stdout shrank or exceeded 8 MiB')
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
