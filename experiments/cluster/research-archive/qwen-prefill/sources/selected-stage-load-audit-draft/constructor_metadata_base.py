#!/usr/bin/env python3
"""Independent fixed-profile metadata replay; no MLX or model payload reads."""
import argparse
import base64
import hashlib
import json
import math
import os
from pathlib import Path
import re
import sys

ROOT = Path('/Users/developer/DarkbloomDev')
FIXTURE = ROOT / 'd-inference/experiments/cluster/inference/Tests/RegisteredDenseProfiles/retained-inputs.json'
FIXTURE_SHA = '1a7e2d74df5e055ec31c12478f49d1d07d1bb48cc64d150248859defb518cd25'
PROFILES = {
    'registered_qwen35_9b': ('nine', 32, 4096, '4a543a467846927736165c44a68802ad15794482ffdf3a1c60113a38c6abfb51'),
    'registered_qwen38_27b': ('twentySeven', 64, 5120, 'ebe2ded36d62a6f83bfa1c1b69951a8e24e9e63094745eb60c4bb353c8951624'),
}
DTYPE = {'U32': 'uint32', 'F32': 'float32', 'BF16': 'bfloat16', 'F16': 'float16'}
WIDTH = {'uint32': 4, 'float32': 4, 'bfloat16': 2, 'float16': 2}


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False, allow_nan=False).encode()


def pairs(values):
    result = {}
    for key, value in values:
        if key in result:
            raise ValueError('Duplicate JSON key')
        result[key] = value
    return result


def decode(raw):
    def refuse(_):
        raise ValueError('Non-integer or nonfinite metadata number')
    return json.loads(raw, object_pairs_hook=pairs, parse_float=refuse, parse_constant=refuse)


def layout(records, name_key, dtype_key):
    lines = [f'{r[name_key]}:{r[dtype_key]}:{r["shape"]}' for r in records]
    return sha('\n'.join(sorted(lines)).encode())


def parameter(name, shape, dtype):
    return dict(name=name, shape=shape, constructorDType=dtype,
                logicalByteCount=math.prod(shape) * WIDTH[dtype])


def check_constructor(actual, expected, role, layers):
    expected = sorted(expected, key=lambda row: row['name'])
    for row in actual['parameters']:
        assert all(type(x) is int for x in row['shape']), 'Constructor shape uses noninteger dimensions'
    assert actual['role'] == role and actual['layerCount'] == layers
    assert actual['parameters'] == expected, 'Actual constructor geometry/dtype differs from independent expectation'
    assert actual['logicalParameterBytes'] == sum(p['logicalByteCount'] for p in expected)
    assert actual['parameterMetadataSHA256'] == sha(canonical(expected))
    assert actual['modelReleased'] is True
    for key in ['parameterValuesEvaluated', 'checkpointWeightsInstalled', 'logicalBytesAreAllocationMeasurement']:
        assert actual[key] is False, key


def require_integer_metadata(report):
    """Exact Int fields from the existing DTO; Boolean flags keep their old checks."""
    def fields(value, names, path):
        for name in names:
            if type(value[name]) is not int:
                raise ValueError('Expected integer metadata at ' + path + '.' + name)
    def tensors(values, byte_field, path):
        for index, value in enumerate(values):
            local = path + '[' + str(index) + ']'
            fields(value, [byte_field], local)
            if type(value['shape']) is not list or any(type(x) is not int for x in value['shape']):
                raise ValueError('Expected integer tensor shape at ' + local + '.shape')
    def constructor(value, path):
        fields(value, ['layerCount', 'logicalParameterBytes'], path)
        tensors(value['parameters'], 'logicalByteCount', path + '.parameters')
    fields(report, ['schemaVersion', 'sourceTensorCount', 'sourceTensorBytes',
        'largestSourceTensorBytes', 'fullCheckpointVerificationPasses', 'constructorsInspected'], 'report')
    fields(report['arithmeticEnvironment'], ['full512TokenChunkQueryBlocks'], 'report.arithmeticEnvironment')
    tensors(report['sourceTensors'], 'byteCount', 'report.sourceTensors')
    for index, value in enumerate(report['sourceTensors']):
        fields(value, ['offset'], 'report.sourceTensors[' + str(index) + ']')
    constructor(report['fullConstructor'], 'report.fullConstructor')
    for index, stage in enumerate(report['stages']):
        local = 'report.stages[' + str(index) + ']'
        constructor(stage['constructor'], local + '.constructor')
        tensors(stage['expectedActiveTensors'], 'byteCount', local + '.expectedActiveTensors')
        for module_index, module in enumerate(stage['installedLazyInertModules']):
            tensors(module['parameters'], 'byteCount', local + '.installedLazyInertModules[' +
                    str(module_index) + '].parameters')
        fields(stage['expectedPostLoadSummary'], ['stageIndex', 'loadedTensorBytes',
            'activeTensorCount', 'inertTensorBytes', 'inertTensorCount'], local + '.expectedPostLoadSummary')


def audit(report, fixture):
    require_integer_metadata(report)
    assert report['kind'] == 'qwen_dense_constructor_report' and report['schemaVersion'] == 1
    assert report['scope'] == 'registered_dense_constructor_metadata_only_v1'
    arithmetic = report['arithmeticEnvironment']
    assert arithmetic['contract'] == 'qwen_cbv2_query128_bf16_tf32_default_v1'
    assert arithmetic['requiredValues'] == {
        'DARKBLOOM_BF16_WEIGHTS': '1', 'DARKBLOOM_CBV2_ATTN_QUERY_BLOCK': '128', 'MLX_ENABLE_TF32': '1'}
    assert arithmetic['requiredAbsentNames'] == ['MLX_METAL_GPU_ARCH', 'MLX_SDPA_BLOCKS']
    assert arithmetic['full512TokenChunkQueryBlocks'] == 4
    assert arithmetic['numericalOrPerformanceQualificationEstablished'] is False
    name, layers, hidden, inventory_pin = PROFILES[report['model']]
    retained = fixture[name]
    config_raw, manifest_raw = [base64.b64decode(retained[key], validate=True) for key in ['configuration', 'manifest']]
    manifest = decode(manifest_raw)
    expected = sorted(retained['canonicalTensors'], key=lambda row: row['name'])
    expected_by_name = {row['name']: row for row in expected}
    assert len(expected_by_name) == len(expected)
    assert report['configurationSHA256'] == sha(config_raw)
    assert report['manifestSHA256'] == sha(manifest_raw)
    assert report['verifiedAggregateSHA256'] == manifest['aggregate_sha256']
    inventory = '\n'.join(f'{r["name"]}|{r["sourceDType"]}|{",".join(map(str,r["shape"]))}|{r["byteCount"]}' for r in expected)
    assert report['canonicalInventorySHA256'] == sha(inventory.encode()) == inventory_pin
    assert report['sourceTensorCount'] == len(expected)
    assert report['sourceTensorBytes'] == sum(r['byteCount'] for r in expected)
    assert report['largestSourceTensorBytes'] == max(r['byteCount'] for r in expected)

    source = report['sourceTensors']
    assert [r['sourceName'] for r in source] == sorted(expected_by_name)
    files = {entry['path']: entry['size_bytes'] for entry in manifest['files']}
    ranges = {}
    for row, wanted in zip(source, expected):
        assert all(type(x) is int for x in row['shape'])
        assert row['canonicalPartName'] == wanted['name']
        assert row['shape'] == wanted['shape'] and row['byteCount'] == wanted['byteCount']
        assert row['sourceDType'] == DTYPE[wanted['sourceDType']]
        assert row['loadedDType'] == ('bfloat16' if wanted['sourceDType'] == 'F16' else row['sourceDType'])
        assert row['file'] in files and row['file'].endswith('.safetensors')
        assert type(row['offset']) is int and row['offset'] >= 8
        assert row['offset'] + row['byteCount'] <= files[row['file']]
        ranges.setdefault(row['file'], []).append((row['offset'], row['offset'] + row['byteCount']))
    for intervals in ranges.values():
        intervals.sort()
        assert all(a[1] <= b[0] for a, b in zip(intervals, intervals[1:])), 'Canonical source intervals overlap'
    assert report['sourceTensorManifestSHA256'] == sha(canonical(source))
    assert report['expectedSourceParameterLayoutSHA256'] == layout(source, 'sourceName', 'loadedDType')
    full = [parameter(r['name'], r['shape'], 'uint32' if r['sourceDType'] == 'U32' else 'float32') for r in expected]
    check_constructor(report['fullConstructor'], full, 'full', layers)
    assert report['fullConstructor']['configurationSHA256'] == sha(config_raw)

    expected_active = [[], []]
    for row in source:
        original = row['sourceName']
        match = re.fullmatch(r'(language_model\.model\.layers\.)(\d+)(\..+)', original)
        if match:
            global_layer = int(match[2]); assert 0 <= global_layer < layers
            owner = int(global_layer >= layers // 2)
            local = match[1] + str(global_layer - owner * (layers // 2)) + match[3]
        elif original.startswith('language_model.model.embed_tokens.'):
            owner, local = 0, original
        elif original.startswith('language_model.lm_head.') or original == 'language_model.model.norm.weight':
            owner, local = 1, original
        else:
            raise AssertionError('Unknown canonical ownership')
        expected_active[owner].append({key: row[key] for key in ['sourceName', 'shape', 'sourceDType', 'loadedDType', 'byteCount']} | {'localName': local})

    assert len(report['stages']) == 2
    counts = []
    for index, stage in enumerate(report['stages']):
        assert stage['actualLoadedInventoryEstablished'] is False
        active = sorted(expected_active[index], key=lambda row: row['localName'])
        assert stage['expectedActiveTensors'] == active
        inert = ([('language_model.lm_head', [1, hidden], 'module-replacement'),
                  ('language_model.model.norm', [hidden], 'parameter-only-replacement')]
                 if index == 0 else [('language_model.model.embed_tokens', [1, hidden], 'module-replacement')])
        actual_inert = stage['installedLazyInertModules']
        assert len(actual_inert) == len(inert)
        inert_parameters = []
        for actual, (path, shape, replacement) in zip(actual_inert, inert):
            wanted = dict(localName=path + '.weight', shape=shape, dtype='bfloat16', byteCount=math.prod(shape) * 2)
            assert actual['path'] == path and actual['replacementKind'] == replacement
            assert actual['parameters'] == [wanted]
            inert_parameters.append(wanted)
        parameters = [parameter(r['localName'], r['shape'], 'uint32' if r['sourceDType'] == 'uint32' else 'float32') for r in active]
        parameters += [parameter(r['localName'], r['shape'], r['dtype']) for r in inert_parameters]
        check_constructor(stage['constructor'], parameters, f'stage{index}', layers // 2)
        summary = stage['expectedPostLoadSummary']
        assert summary['stageIndex'] == index
        assert summary['constructionConfigurationSHA256'] == stage['constructor']['configurationSHA256']
        assert summary['activeMappingSHA256'] == sha(canonical(active))
        assert summary['activeParameterLayoutSHA256'] == layout(active, 'localName', 'loadedDType')
        total_layout = [{'name': r['localName'], 'dtype': r['loadedDType'], 'shape': r['shape']} for r in active]
        total_layout += [{'name': r['localName'], 'dtype': r['dtype'], 'shape': r['shape']} for r in inert_parameters]
        assert summary['parameterLayoutSHA256'] == layout(total_layout, 'name', 'dtype')
        assert summary['loadedTensorBytes'] == sum(r['byteCount'] for r in active)
        assert summary['activeTensorCount'] == len(active)
        assert summary['inertTensorBytes'] == sum(r['byteCount'] for r in inert_parameters)
        assert summary['inertTensorCount'] == len(inert_parameters)
        counts.append(dict(active=len(active), inert=len(inert_parameters), constructor=len(parameters)))

    for key in ['completed', 'correctnessOnly', 'allConstructorModelsReleased', 'verifiedFileOwnerReleased',
                'cacheClearCompleted', 'checkpointFileBytesHashed', 'nativeConstructorOperationsUsed']:
        assert report[key] is True, key
    for key in ['throughputMeasurementValid', 'sourceTensorPayloadsMaterialized', 'forwardExecuted',
                'requestStateCreated', 'loadedStageReceiptProduced', 'nativeAllocationFree',
                'parameterValuesEvaluated', 'numericalParityEstablished', 'providerEligibilityEstablished',
                'independentResourceAdmissionEstablished', 'weightMaterializationAuthorized',
                'forwardExecutionAuthorized', 'isWholeProcessMemoryBound', 'physicalTransferQualified']:
        assert report[key] is False, key
    assert report['fullCheckpointVerificationPasses'] == 1 and report['constructorsInspected'] == 3
    for key in ['planSHA256', 'profileFingerprint']:
        assert re.fullmatch('[0-9a-f]{64}', report[key])
    return dict(passed=True, model=report['model'], sourceTensors=len(expected), stages=counts,
        rawMetadataIdentitiesAndCanonicalInventoryMatched=True,
        fullAndCompactConstructorGeometryAndDTypeMatched=True, halfOwnershipIndependentlyReplayed=True,
        loadedExpectationsKeptSeparate=True, sourceOffsetsBoundedButHeadersNotIndependentlyReplayed=True,
        planSerializationIndependentlyReplayed=False, nativeReleaseIndependentlyObserved=False,
        modelNumericsQualified=False, performanceQualified=False)


def audit_files(stdout_path, output_path):
    """Publish one new success or failure receipt; never rewrite native evidence."""
    if output_path.exists():
        raise FileExistsError('Audit output must be new')
    result = dict(kind='independent_dense_constructor_metadata_audit', schemaVersion=1,
        passed=False, status='failed', stdoutSHA256=None, fixtureSHA256=FIXTURE_SHA,
        auditorSHA256=sha(Path(__file__).read_bytes()), primaryFailure=None,
        modelNumericsQualified=False, performanceQualified=False)
    try:
        assert stdout_path.stat().st_size <= 8 * 1024**2
        fixture_raw = FIXTURE.read_bytes(); assert sha(fixture_raw) == FIXTURE_SHA
        with stdout_path.open('rb') as stream:
            raw = stream.read(8 * 1024**2 + 1)
        assert len(raw) <= 8 * 1024**2
        result['stdoutSHA256'] = sha(raw)
        lines = raw.splitlines(); assert len(lines) == 1
        result.update(audit(decode(lines[0]), decode(fixture_raw)))
        result['status'] = 'passed'
    except Exception as error:
        result['primaryFailure'] = dict(type=type(error).__name__, message=str(error))
    raw_result = json.dumps(result, indent=2, sort_keys=True, allow_nan=False).encode() + b'\n'
    descriptor = os.open(output_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, 'wb') as stream:
        stream.write(raw_result)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--stdout', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    result = audit_files(args.stdout, args.output)
    print(json.dumps(result, sort_keys=True))
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    sys.exit(main())
