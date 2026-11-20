"""Closed selected-stage parent predicates; no native allocation permission."""
from decimal import Decimal
import hashlib
import json
import os
from pathlib import Path
import re
import stat

GIB = 1024**3
MINIMUM_FREE = 6 * GIB
MAX_STDOUT = 8 * 1024**2
MAX_STDERR = 65536
NATIVE_SECONDS = 120
PARENT_SECONDS = 135
PROFILES = {
    'registered_qwen35_9b': {
        'configuration': 'c8e767de4953e58352fbc1acbf6615329075ed02fe16a36b8065714d85ee4423',
        'manifest': '4f2735026cc7b40ee2c886ee53fb8755816c0001c4c69c141a61d5f56ff22aa4',
        'artifact': '127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b',
        'canonicalTensorCount': 927, 'maximumSampledRSSBytes': 4 * GIB,
    },
    'registered_qwen38_27b': {
        'configuration': '4691da94a1b4ef415aad112ec46abebd33f8a41ad07380e486c0526eb945c1ff',
        'manifest': 'd1239a5bc6d26d5ce4bf87f22270e3a703f4942e3d0d779948b4f65410df6dcc',
        'artifact': 'bbd0e0adcfe74e095073fefd0b9e116e4311d606ad9989cf81f8175e8ac18463',
        'canonicalTensorCount': 1847, 'maximumSampledRSSBytes': 10 * GIB,
    },
}


def require(value, message):
    if not value:
        raise ValueError(message)


def bounded_regular(path, maximum):
    """Small metadata/output bytes only; never a checkpoint payload."""
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        before = os.fstat(fd)
        require(stat.S_ISREG(before.st_mode) and 0 <= before.st_size <= maximum,
                'Expected bounded regular file')
        with os.fdopen(fd, 'rb', closefd=False) as stream:
            data = stream.read(maximum + 1)
        after = os.fstat(fd)
        stamp = lambda s: (s.st_dev, s.st_ino, s.st_mode, s.st_size, s.st_mtime_ns, s.st_ctime_ns)
        require(stamp(before) == stamp(after) and len(data) == before.st_size and len(data) <= maximum,
                'Bounded file changed during read')
        return data
    finally:
        os.close(fd)


def input_pins(directory, profile):
    result = {}
    for name, key, limit in [('config.json', 'configuration', 65536),
                             ('manifest.json', 'manifest', 4 * 1024**2)]:
        data = bounded_regular(Path(directory) / name, limit)
        require(hashlib.sha256(data).hexdigest() == profile[key], 'Registered raw metadata pin differs')
        result[name] = dict(sizeBytes=len(data), sha256=profile[key])
    return result


def power_policy(raw):
    require(type(raw) is str and len(raw.encode()) <= 65536, 'Invalid bounded power observation')
    sources = re.findall(r"^Now drawing from '(AC Power|Battery Power)'$", raw, re.M)
    require(len(sources) == 1, 'Power source is unknown or ambiguous')
    if sources[0] == 'AC Power':
        return dict(source='AC Power', batteryPercent=None, batteryFloorApplied=False)
    values = re.findall(r'^\s*-InternalBattery[^\n]*?\s(\d+)%;', raw, re.M)
    require(len(values) == 1 and 15 <= int(values[0]) <= 100,
            'Battery observation is missing or below 15 percent')
    return dict(source='Battery Power', batteryPercent=int(values[0]), batteryFloorApplied=True)


def resource_policy(observation, profile, expected_pid=None, expected_executable=None, terminal_exit_code=None):
    require(type(observation.get('actualFreeBytes')) is int and observation['actualFreeBytes'] >= MINIMUM_FREE,
            'Actual free memory is below 6 GiB')
    require(type(observation.get('pressureLevel')) is int and 0 <= observation['pressureLevel'] <= 2,
            'Memory pressure exceeds selected-stage screen')
    require(type(observation.get('reportedSwapBytes')) is str and
            Decimal(observation['reportedSwapBytes']) == 0, 'Reported swap must be absolute zero')
    rss = observation.get('nativeRSSBytes')
    defunct = observation.get('nativeCommand') == '<defunct>'
    if defunct:
        require(type(rss) is int and rss == 0 and type(terminal_exit_code) is int,
                'Defunct sample lacks zero RSS and confirmed terminal owned process')
    if rss is not None:
        require(type(rss) is int and 0 <= rss <= profile['maximumSampledRSSBytes'],
                'Sampled native RSS exceeds selected-stage screen')
        require(type(expected_pid) is int and type(observation.get('nativePID')) is int and
                type(observation.get('nativePGID')) is int and observation['nativePID'] == expected_pid and
                observation['nativePGID'] == expected_pid, 'Sample belongs to another native process group')
        require(type(observation.get('nativeCommand')) is str and (defunct or
                observation['nativeCommand'].startswith(str(expected_executable) + ' --mode qwen-dense-stage-load-check ')),
                'Sample belongs to another native command')


def native_command(executable, directory, profile, stage_index):
    require(profile in PROFILES and type(stage_index) is int and stage_index in (0, 1),
            'Only one registered default stage may be selected')
    return [str(executable), '--mode', 'qwen-dense-stage-load-check', '--model-dir', str(directory),
            '--registered-dense-profile', profile, '--stage-index', str(stage_index),
            '--timeout-seconds', str(NATIVE_SECONDS)]


def _object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, 'Duplicate output JSON key')
        result[key] = value
    return result


TRUE_FLAGS = ('completed', 'selectedStagePayloadMaterialized', 'selectedParametersEvaluated',
    'allConstructorModelsReleased', 'verifiedFileOwnerReleased', 'cacheClearCompleted',
    'actualLocalResourceAdmissionPerformed', 'parentProcessFencingIndependentlyRequired')
FALSE_FLAGS = ('fullModelWeightsLoaded', 'forwardExecuted', 'requestStateCreated',
    'tensorValuesIndependentlyCompared', 'numericalParityEstablished', 'providerEligibilityEstablished',
    'forwardExecutionAuthorized', 'wholeProcessMemorySafetyEstablished', 'throughputMeasurementValid')
REPORT_KEYS = set(TRUE_FLAGS + FALSE_FLAGS + ('kind', 'schemaVersion', 'model', 'stageIndex',
    'profileFingerprint', 'arithmeticEnvironment', 'load', 'budget', 'initialResources',
    'loadingResources', 'releasedResources', 'memory', 'runtime', 'selectedStageModelsLoaded',
    'fullCheckpointVerificationPasses'))


def validate_result(raw, profile_name, stage_index):
    """Outer identity/scope only. Tensor inventories and resource DTOs stay opaque."""
    require(0 < len(raw) <= MAX_STDOUT and raw.endswith(b'\n') and len(raw.splitlines()) == 1,
            'Expected exactly one bounded complete result line')
    def invalid_constant(value):
        raise ValueError('Non-finite JSON token: ' + value)
    result = json.loads(raw, object_pairs_hook=_object, parse_constant=invalid_constant)
    require(type(result) is dict and set(result) == REPORT_KEYS and
            result['kind'] == 'qwen_dense_stage_load_report', 'Unexpected selected-stage result envelope')
    for key in TRUE_FLAGS:
        require(result[key] is True, 'Expected true loading-only claim: ' + key)
    for key in FALSE_FLAGS:
        require(result[key] is False, 'Unexpected qualification claim: ' + key)
    for key in ('schemaVersion', 'selectedStageModelsLoaded', 'fullCheckpointVerificationPasses'):
        require(type(result[key]) is int and result[key] == 1, 'Expected exact single-load count: ' + key)
    require(result['model'] == profile_name and type(result['stageIndex']) is int and
            result['stageIndex'] == stage_index, 'Selected-stage result identity differs')
    load, budget = result['load'], result['budget']
    require(type(load) is dict and type(budget) is dict, 'Missing selected-stage load or budget')
    for entry in (load, budget):
        require(type(entry.get('stageIndex')) is int and entry['stageIndex'] == stage_index,
                'Nested selected-stage index differs')
    require(type(load.get('schemaVersion')) is int and load['schemaVersion'] == 1,
            'Load receipt schema differs')
    profile = PROFILES[profile_name]
    require(load.get('verifiedAggregateSHA256') == profile['artifact'] and
            load.get('sourceConfigurationSHA256') == profile['configuration'] and
            load.get('bf16ConversionEnabled') is True, 'Load source or BF16 identity differs')
    require(budget.get('model') == profile_name and budget.get('resourceAdmissionPerformed') is False and
            budget.get('forwardExecutionAuthorized') is False, 'Metadata budget identity/scope differs')
    fingerprint = result['profileFingerprint']
    require(type(fingerprint) is str and re.fullmatch('[0-9a-f]{64}', fingerprint) and
            budget.get('profileFingerprint') == fingerprint, 'Profile identity is incoherent')
    plan = load.get('planSHA256')
    require(type(plan) is str and re.fullmatch('[0-9a-f]{64}', plan) and
            budget.get('planFingerprint') == plan, 'Retained Plan identity is incoherent')
    return dict(resultRecordCount=1, resultKind=result['kind'], profileFingerprint=fingerprint,
                planFingerprint=plan, outerIdentityAndScopeValidated=True,
                independentMetadataAuditPerformed=False, independentTensorAuditPerformed=False)
