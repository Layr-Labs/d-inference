"""Bounded outer records only; the independent oracle audits producer evidence."""
import json
import math
from pathlib import Path
from long_reference_inputs import ARTIFACT, CONFIGURATION, PROFILE, PROFILE_SHA256, is_sha256, require

FIRST, FINAL = 'qwen_long_prefill_reference_ready', 'qwen_long_prefill_reference_report'
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
    keys = {'kind', 'schemaVersion', 'correctnessOnly', 'throughputMeasurementValid',
            'verifiedModelLoaded', 'freshRequestStateCreated', 'profile', 'profileFingerprint',
            'promptFileSHA256', 'arithmeticEnvironmentSHA256', 'recordedRequestFingerprint'}
    require(set(record) == keys and record['kind'] == FIRST
            and type(record['schemaVersion']) is int and record['schemaVersion'] == 1,
            'Expected exact pre-load admitted-ready record first')
    flags(record, correctnessOnly=True, throughputMeasurementValid=False,
          verifiedModelLoaded=False, freshRequestStateCreated=False)
    require(record['profile'] == PROFILE and record['profileFingerprint'] == PROFILE_SHA256
            and record['promptFileSHA256'] == inputs['prompt_file_sha256']
            and is_sha256(record['arithmeticEnvironmentSHA256'])
            and is_sha256(record['recordedRequestFingerprint']), 'Ready input/profile identity differs')


def validate_final(record, first, inputs):
    keys = {'kind', 'schemaVersion', 'completed', 'correctnessOnly', 'throughputMeasurementValid',
            'interprocessTransportUsed', 'physicalTransferQualified', 'allRequestStateRetired',
            'modelReleased', 'evidence', 'memory'}
    require(set(record) == keys and record['kind'] == FINAL
            and type(record['schemaVersion']) is int and record['schemaVersion'] == 1,
            'Wrong terminal namespace/schema or unexpected timing field')
    flags(record, completed=True, correctnessOnly=True, throughputMeasurementValid=False,
          interprocessTransportUsed=False, physicalTransferQualified=False,
          allRequestStateRetired=True, modelReleased=True)
    evidence = record['evidence']
    require(type(evidence) is dict and evidence, 'Missing producer evidence')
    # Bind the producer to this launch. Numerical rows, component inventories,
    # arithmetic receipt contents and inner fingerprints remain oracle-owned.
    for key in ('profile', 'profileFingerprint', 'promptFileSHA256', 'arithmeticEnvironmentSHA256'):
        require(evidence.get(key) == first[key], 'Evidence differs from admitted ready identity: ' + key)
    require(evidence.get('promptTokenIDsSHA256') == inputs['prompt_token_ids_sha256'], 'Wrong logical prompt identity')
    execution = evidence.get('execution')
    require(type(execution) is dict and type(execution.get('request')) is dict
            and execution['request'].get('fingerprint') == first['recordedRequestFingerprint'],
            'Producer request differs from ready request')
    source = execution.get('source', {})
    require(source.get('artifactAggregateSHA256') == ARTIFACT
            and source.get('sourceConfigurationSHA256') == CONFIGURATION, 'Wrong producer source artifact/configuration')
    memory = record['memory']
    require(type(memory) is list and len(memory) == 2, 'Missing native memory phases')
    for value, phase in zip(memory, ['before_full_model_load', 'full_model_released_cache_cleared']):
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
