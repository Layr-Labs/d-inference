#!/usr/bin/env python3
"""Source/pinned-metadata checks only. Does not parse/compile or execute Swift."""
import base64
import hashlib
import json
import math
import re
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent / 'd-inference'
CORE = ['QwenDenseProfileTypes.swift', 'QwenRegisteredDenseModelProfile.swift',
        'QwenDenseRegisteredSpecification.swift', 'QwenDenseStorageRequirement.swift',
        'QwenDenseStateBudget.swift', 'QwenDenseResourcePlanning.swift']
PURE_DEPENDENCIES = ['WorkerJSONScanner.swift', 'BoundedProbeInput.swift', 'QwenLayerStageMetadata.swift',
                     'QwenLayerStagePlan.swift', 'QwenLayerStageCandidates.swift', 'QwenLongPrefillTensorBudget.swift',
                     'QwenRegistered9BLongPrefillAdmission.swift', 'QwenLongPrefillStageCut.swift']


def sha(value):
    return hashlib.sha256(value).hexdigest()


def metadata_signature(values):
    assert 0 < len(values) <= 2048
    assert len({x['name'] for x in values}) == len(values)
    for x in values:
        assert re.fullmatch(r'[A-Za-z0-9_.]{1,512}', x['name'])
        assert 1 <= len(x['shape']) <= 4 and all(type(n) is int and 0 < n <= 2147483647 for n in x['shape'])
        assert x['sourceDType'] in ['U32', 'F32', 'BF16', 'F16']
        width = 4 if x['sourceDType'] in ['U32', 'F32'] else 2
        assert math.prod(x['shape']) * width == x['byteCount'] > 0
    return sha('\n'.join(x['name'] + '|' + x['sourceDType'] + '|' + ','.join(map(str, x['shape'])) + '|' + str(x['byteCount'])
                         for x in sorted(values, key=lambda v: v['name'])).encode())


def main():
    sources = {n: (HERE / n).read_bytes() for n in CORE}
    for name, data in sources.items():
        text = data.decode()
        assert set(re.findall(r'^import (\w+)', text, re.M)) <= {'Foundation', 'CryptoKit'}
        for forbidden in ['FileHandle.', 'ProcessInfo.', 'DispatchTime.', 'MLXArray(', 'loadVerifiedQwen', 'Stream.gpu']:
            assert forbidden not in text, (name, forbidden)
    assert 'private init(spec:' in sources['QwenRegisteredDenseModelProfile.swift'].decode()
    assert 'private init(profile:' in sources['QwenDenseStorageRequirement.swift'].decode()
    assert 'runtimeExecutionAuthorized = false' in sources['QwenDenseResourcePlanning.swift'].decode()
    assert 'provenanceVerified = false' in sources['QwenDenseResourcePlanning.swift'].decode()
    spec = sources['QwenDenseRegisteredSpecification.swift'].decode()
    raw_inputs = (HERE / 'retained-inputs.json').read_bytes()
    assert len(raw_inputs) <= 1_048_576
    fixtures = json.loads(raw_inputs)
    origins = json.loads((HERE / 'retained-input-pins.json').read_bytes())
    origin_data = {}
    for entry in origins:
        with Path(entry['path']).open('rb') as handle:
            data = handle.read(2_097_153)
        assert len(data) <= 2_097_152 and len(data) == entry['byteCount'] and sha(data) == entry['sha256']
        origin_data[entry['path']] = data
    old = json.loads(next(data for p, data in origin_data.items() if p.endswith('/qwen-layer-stage-real9b-expected-20260913.json')))
    layout = json.loads(next(data for p, data in origin_data.items() if p.endswith('/Qwen3.8-27B/weight-layout.json')))
    dtype_names = {'uint32': 'U32', 'float32': 'F32', 'float16': 'F16', 'bfloat16': 'BF16'}
    expected = {
        'nine': [{'name': x['sourceName'], 'shape': x['shape'], 'sourceDType': dtype_names[x['sourceDType']], 'byteCount': x['byteCount']}
                 for x in old['fullCanonicalTensors']],
        'twentySeven': [{'name': n, 'shape': x['shape'], 'sourceDType': x['dtype'], 'byteCount': x['bytes']}
                        for n, x in layout['tensors'].items() if n.startswith('language_model.')],
    }
    metadata = []
    for key, fixture in fixtures.items():
        config = base64.b64decode(fixture['configuration'], validate=True)
        manifest = base64.b64decode(fixture['manifest'], validate=True)
        assert config in origin_data.values() and manifest in origin_data.values()
        assert sha(config) in spec and sha(manifest) in spec
        signature = metadata_signature(fixture['canonicalTensors'])
        assert signature in spec
        assert fixture['canonicalTensors'] == sorted(expected[key], key=lambda x: x['name'])
        assert signature == metadata_signature(list(reversed(fixture['canonicalTensors'])))
        declared = json.loads(manifest)
        assert declared['aggregate_sha256'] in spec
        assert declared['total_size_bytes'] == sum(x['size_bytes'] for x in declared['files'])
        assert sum(x['byteCount'] for x in fixture['canonicalTensors']) == (5_038_041_600 if key == 'nine' else 15_132_802_048)
        metadata.append({'fixture': key, 'configurationSHA256': sha(config), 'manifestSHA256': sha(manifest),
                         'canonicalInventorySHA256': signature, 'canonicalCount': len(fixture['canonicalTensors'])})
    dependencies = []
    for name in PURE_DEPENDENCIES:
        p = REPO / 'experiments/cluster/inference/Sources/ClusterInference' / name
        data = p.read_bytes()
        dependencies.append({'path': str(p), 'name': name, 'byteCount': len(data), 'sha256': sha(data), 'role': 'pure_dependency'})
    p = REPO / 'experiments/cluster/inference/Tests/LayerStageCandidates/TestSupport.swift'
    data = p.read_bytes()
    dependencies.append({'path': str(p), 'name': p.name, 'byteCount': len(data), 'sha256': sha(data), 'role': 'standalone_test_support'})
    for entry in origins:
        assert sha(Path(entry['path']).read_bytes()) == entry['sha256']
    for entry in dependencies:
        assert sha(Path(entry['path']).read_bytes()) == entry['sha256']
    assert all((HERE / name).read_bytes() == data for name, data in sources.items())
    dependency_text = json.dumps({'kind': 'registered_dense_profile_pure_dependencies',
        'schemaVersion': 1, 'files': dependencies}, sort_keys=True, indent=2) + '\n'
    receipt = {'kind': 'registered_dense_profile_source_metadata_check', 'schemaVersion': 1, 'status': 'passed',
        'coreSourceFiles': len(CORE), 'pureDependenciesAndTestSupport': len(dependencies), 'retainedOrigins': len(origins),
        'fixtureBytes': len(raw_inputs), 'metadata': metadata,
        'swiftCompiledOrExecuted': False, 'swiftFixtureOutcome': 'pending root compilation and execution',
        'modelPayloadBytesRead': 0, 'newSafetensorHeaderRead': False, 'repositoryEdited': False,
        'sourceAndRetainedMetadataUnchanged': True, 'executionPermitMinted': False}
    for name, content in [('source-pins.json', dependency_text),
                          ('source-checks.json', json.dumps(receipt, sort_keys=True, indent=2) + '\n')]:
        path = HERE / name
        if path.exists():
            assert path.read_text() == content, 'Existing frozen evidence differs: ' + name
        else:
            with path.open('x') as handle:
                handle.write(content)
    print(json.dumps(receipt, sort_keys=True))


if __name__ == '__main__':
    main()
