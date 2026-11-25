"""Read-only CPU replay of one completed constructor run; never executes its files."""
import base64
from collections import Counter
from datetime import datetime, timezone
from decimal import Decimal
import hashlib
import json
import math
from pathlib import Path, PurePosixPath
import re
import stat

ROOT = Path('/Users/developer/DarkbloomDev')
RUN = ROOT / 'cluster-research/runs/dense-constructor-27b-stage-build-20260914'
OUT = Path(__file__).parent
PINS = {
    'receipt.json': 'e1e86cc81db61832e9755d5fd1740f6d829fbf39799e0402b8c015f78ecd9183',
    'stdout.jsonl': '563414858fcec6228884c13b9b1aa8669d1c22097bd10b848a60f820aca51794',
}
NATIVE = '42d8990283ddbdd47690d6b3bcb8c7fbb75df8919e5a71c150680ebe4a4dcb8d'
FIXTURE_PIN = '1a7e2d74df5e055ec31c12478f49d1d07d1bb48cc64d150248859defb518cd25'
AUDITOR_PIN = '21e17929e3af35f45d23101c3280ea061450c2a44865b3d7ab04c9ec3a2bb876'
WIDTH = {'uint32': 4, 'float32': 4, 'bfloat16': 2, 'float16': 2}
DTYPE = {'U32': 'uint32', 'F32': 'float32', 'BF16': 'bfloat16', 'F16': 'float16'}


def sha(data):
    return hashlib.sha256(data).hexdigest()


def file_pin(path):
    before = path.stat()
    assert stat.S_ISREG(before.st_mode) and before.st_size <= 512 * 1024**2
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024**2), b''):
            value.update(block)
    after = path.stat()
    assert (before.st_ino, before.st_size, before.st_mtime_ns) == (after.st_ino, after.st_size, after.st_mtime_ns)
    return {'size_bytes': before.st_size, 'sha256': value.hexdigest()}


def pairs(values):
    result = {}
    for k, v in values:
        assert k not in result
        result[k] = v
    return result


def read_json(path, limit):
    with path.open('rb') as stream:
        raw = stream.read(limit + 1)
    assert len(raw) <= limit
    return raw, json.loads(raw, object_pairs_hook=pairs)


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False, allow_nan=False).encode()


def logical_bytes(shape, dtype):
    assert type(shape) is list and all(type(x) is int and x > 0 for x in shape)
    return math.prod(shape) * WIDTH[dtype]


def parameter(name, shape, dtype):
    return dict(name=name, shape=shape, constructorDType=dtype,
                logicalByteCount=logical_bytes(shape, dtype))


def constructor(value, expected, role, layers):
    expected = sorted(expected, key=lambda r: r['name'])
    assert value['parameters'] == expected
    assert type(value['layerCount']) is int and value['layerCount'] == layers and value['role'] == role
    assert value['logicalParameterBytes'] == sum(r['logicalByteCount'] for r in expected)
    assert value['parameterMetadataSHA256'] == sha(canonical(expected))
    assert value['modelReleased'] is True
    for key in ('checkpointWeightsInstalled', 'parameterValuesEvaluated', 'logicalBytesAreAllocationMeasurement'):
        assert value[key] is False
    return {'parameters': len(expected), 'logicalBytes': value['logicalParameterBytes'],
            'dtypeCounts': dict(sorted(Counter(r['constructorDType'] for r in expected).items()))}


def main():
    inputs = {n: file_pin(RUN / n) for n in ('receipt.json', 'stdout.jsonl', 'stderr.log', 'metadata-audit-v2.json', 'source-manifest.json')}
    for name, pin in PINS.items():
        assert inputs[name]['sha256'] == pin
    _, receipt = read_json(RUN / 'receipt.json', 1024**2)
    raw, report = read_json(RUN / 'stdout.jsonl', 8 * 1024**2)
    assert len(raw.splitlines()) == 1 and inputs['stderr.log']['size_bytes'] == 0
    _, audit = read_json(RUN / 'metadata-audit-v2.json', 65536)
    assert receipt['status'] == 'completed' and receipt['nativeExitCode'] == 0 and receipt['nativeReaped'] is True
    assert receipt['nativeExecutions'] == receipt['resultRecordCount'] == 1
    assert receipt['primaryFailure'] is None and not receipt['cleanupErrors'] and not receipt['postRunErrors']
    assert receipt['ownedProcessGroupAfter'] == []
    assert receipt['expectedNativeSHA256'] == NATIVE
    assert receipt['sourceManifestSHA256'] == inputs['source-manifest.json']['sha256']
    for name in ('stdout.jsonl', 'stderr.log'):
        assert receipt[name]['sha256'] == inputs[name]['sha256'] and receipt[name]['sizeBytes'] == inputs[name]['size_bytes']
    expected_command = [str(RUN / 'bundle/cluster-inference'), '--mode', 'qwen-dense-constructor-check',
                        '--model-dir', str(ROOT / 'models/Qwen3.8-27B'), '--registered-dense-profile',
                        'registered_qwen38_27b', '--timeout-seconds', '120']
    assert receipt['command'] == expected_command and receipt['parentExecutionTimeoutSeconds'] == 135
    assert audit['passed'] is True and audit['status'] == 'passed' and audit['primaryFailure'] is None
    assert audit['stdoutSHA256'] == PINS['stdout.jsonl'] and audit['auditorSHA256'] == AUDITOR_PIN
    assert file_pin(ROOT / 'cluster-research/dense-constructor-metadata-audit-v2-draft/audit_dense_constructor_metadata_v2.py')['sha256'] == AUDITOR_PIN

    _, source_manifest = read_json(RUN / 'source-manifest.json', 1024**2)
    source_files = source_manifest['files']
    assert len(source_files) == receipt['sourceFileCount'] == 379
    current_source_drift = []
    for row in source_files:
        name = PurePosixPath(row['path'])
        assert not name.is_absolute() and '..' not in name.parts and str(name) == row['path']
        expected = {k: row[k] for k in ('size_bytes', 'sha256')}
        assert file_pin(RUN / 'source' / str(name)) == expected
        current = ROOT / 'd-inference' / str(name)
        if not current.is_file() or file_pin(current) != expected:
            current_source_drift.append(str(name))
    driver_pins = {}
    for name, field in [('run-dense-constructor-probe-20260914.py', 'driverSHA256'),
                        ('run-profiled-tiny-stage-check-20260914.py', 'tinySupportSHA256'),
                        ('prefill_compute_archive.py', 'archiveSupportSHA256')]:
        driver_pins[name] = file_pin(RUN / name)
        assert driver_pins[name]['sha256'] == receipt[field]
    raw_bundle, bundle = read_json(RUN / 'bundle/bundle.json', 1024**2)
    assert sha(raw_bundle) == receipt['bundleManifestSHA256']
    for row in bundle['files']:
        assert file_pin(RUN / 'bundle' / row['path']) == {k: row[k] for k in ('size_bytes', 'sha256')}
    assert next(r for r in bundle['files'] if r['path'] == 'cluster-inference')['sha256'] == NATIVE
    expected_tree = {'bundle.json'}
    for row in bundle['files']:
        name = PurePosixPath(row['path']); expected_tree.add(str(name))
        expected_tree.update(str(p) for p in name.parents if str(p) != '.')
    extra = []
    finish = datetime.fromisoformat(receipt['finishedAtUTC']).timestamp()
    for path in sorted((RUN / 'bundle').rglob('*')):
        name = str(path.relative_to(RUN / 'bundle'))
        if name not in expected_tree:
            info = path.lstat()
            item = {'path': name, 'mode': oct(stat.S_IMODE(info.st_mode)), 'sizeBytes': info.st_size,
                    'mtimeUTC': datetime.fromtimestamp(info.st_mtime, timezone.utc).isoformat(),
                    'savedFilesystemMtimeAfterConstructorReceiptFinish': info.st_mtime > finish}
            if path.is_file():
                item['sha256'] = file_pin(path)['sha256']
            extra.append(item)

    fixture_path = ROOT / 'd-inference/experiments/cluster/inference/Tests/RegisteredDenseProfiles/retained-inputs.json'
    fixture_raw, fixture = read_json(fixture_path, 1024**2)
    assert sha(fixture_raw) == audit['fixtureSHA256'] == FIXTURE_PIN
    retained = fixture['twentySeven']
    config_raw = base64.b64decode(retained['configuration'], validate=True)
    manifest_raw = base64.b64decode(retained['manifest'], validate=True)
    manifest = json.loads(manifest_raw, object_pairs_hook=pairs)
    assert sha(config_raw) == report['configurationSHA256'] == receipt['rawMetadataPins']['config.json']['sha256']
    assert sha(manifest_raw) == report['manifestSHA256'] == receipt['rawMetadataPins']['manifest.json']['sha256']
    assert len(config_raw) == receipt['rawMetadataPins']['config.json']['sizeBytes'] == 4441
    assert len(manifest_raw) == receipt['rawMetadataPins']['manifest.json']['sizeBytes'] == 3122
    assert report['verifiedAggregateSHA256'] == manifest['aggregate_sha256'] == receipt['expectedIdentity']['artifact']
    tensors = report['sourceTensors']; wanted = sorted(retained['canonicalTensors'], key=lambda r: r['name'])
    assert len(tensors) == len(wanted) == report['sourceTensorCount'] == 1847
    assert len({r['sourceName'] for r in tensors}) == 1847
    source_intervals = {}; file_sizes = {r['path']: r['size_bytes'] for r in manifest['files']}
    for row, expected in zip(tensors, wanted):
        assert row['sourceName'] == row['canonicalPartName'] == expected['name']
        assert row['shape'] == expected['shape'] and row['sourceDType'] == DTYPE[expected['sourceDType']]
        assert row['byteCount'] == expected['byteCount'] == logical_bytes(row['shape'], row['sourceDType'])
        assert row['loadedDType'] == row['sourceDType']
        assert type(row['offset']) is int and row['offset'] >= 8 and row['offset'] + row['byteCount'] <= file_sizes[row['file']]
        source_intervals.setdefault(row['file'], []).append((row['offset'], row['offset'] + row['byteCount']))
    for spans in source_intervals.values():
        spans.sort(); assert all(a[1] <= b[0] for a, b in zip(spans, spans[1:]))
    assert sum(r['byteCount'] for r in tensors) == report['sourceTensorBytes']
    assert max(r['byteCount'] for r in tensors) == report['largestSourceTensorBytes']
    inventory = '\n'.join(f'{r["name"]}|{r["sourceDType"]}|{",".join(map(str,r["shape"]))}|{r["byteCount"]}' for r in wanted)
    assert sha(inventory.encode()) == report['canonicalInventorySHA256']
    assert sha(canonical(tensors)) == report['sourceTensorManifestSHA256']
    full = constructor(report['fullConstructor'], [parameter(r['sourceName'], r['shape'],
                       'uint32' if r['sourceDType'] == 'uint32' else 'float32') for r in tensors], 'full', 64)
    stages = []
    for index, value in enumerate(report['stages']):
        expected_active = []
        for row in tensors:
            name = row['sourceName']; match = re.fullmatch(r'(language_model\.model\.layers\.)(\d+)(\..+)', name)
            if match:
                layer = int(match[2]); assert 0 <= layer < 64
                owner = layer // 32; local = match[1] + str(layer % 32) + match[3]
            else:
                assert name.startswith(('language_model.model.embed_tokens.', 'language_model.lm_head.')) or name == 'language_model.model.norm.weight'
                owner = 0 if name.startswith('language_model.model.embed_tokens.') else 1; local = name
            if owner == index:
                expected_active.append({k: row[k] for k in ('sourceName', 'shape', 'sourceDType', 'loadedDType', 'byteCount')} | {'localName': local})
        expected_active.sort(key=lambda r: r['localName'])
        assert value['expectedActiveTensors'] == expected_active
        inert = [p for m in value['installedLazyInertModules'] for p in m['parameters']]
        inert_shapes = [('language_model.lm_head.weight', [1,5120]), ('language_model.model.norm.weight', [5120])] if index == 0 else [('language_model.model.embed_tokens.weight', [1,5120])]
        assert inert == [dict(localName=n, shape=s, dtype='bfloat16', byteCount=logical_bytes(s, 'bfloat16')) for n,s in inert_shapes]
        params = [parameter(r['localName'], r['shape'], 'uint32' if r['sourceDType'] == 'uint32' else 'float32') for r in expected_active]
        params += [parameter(r['localName'], r['shape'], r['dtype']) for r in inert]
        observed = constructor(value['constructor'], params, 'stage'+str(index), 32)
        summary = value['expectedPostLoadSummary']
        assert summary['activeTensorCount'] == len(expected_active)
        assert summary['loadedTensorBytes'] == sum(r['byteCount'] for r in expected_active)
        assert summary['inertTensorCount'] == len(inert) and summary['inertTensorBytes'] == sum(r['byteCount'] for r in inert)
        assert summary['activeMappingSHA256'] == sha(canonical(expected_active))
        assert value['actualLoadedInventoryEstablished'] is False
        observed.update(stageIndex=index, expectedActiveTensors=len(expected_active), inertTensors=len(inert),
                        expectedLoadedBytes=summary['loadedTensorBytes'], inertBytes=summary['inertTensorBytes'])
        stages.append(observed)
    assert len(stages) == 2 and sum(r['expectedActiveTensors'] for r in stages) == 1847
    assert audit['stages'] == [dict(active=s['expectedActiveTensors'], inert=s['inertTensors'], constructor=s['parameters']) for s in stages]
    for key in ('completed', 'allConstructorModelsReleased', 'verifiedFileOwnerReleased', 'cacheClearCompleted', 'checkpointFileBytesHashed'):
        assert report[key] is True
    for key in ('sourceTensorPayloadsMaterialized', 'forwardExecuted', 'parameterValuesEvaluated', 'loadedStageReceiptProduced',
                'weightMaterializationAuthorized', 'numericalParityEstablished', 'providerEligibilityEstablished',
                'independentResourceAdmissionEstablished', 'isWholeProcessMemoryBound', 'throughputMeasurementValid'):
        assert report[key] is False

    samples = receipt['memorySamples']; swaps = []; rss = []; free = []
    for sample in samples:
        raw_vm = sample['rawVMStat']; raw_mem = sample['rawMemory']
        page = int(re.search(r'page size of (\d+) bytes', raw_vm)[1])
        pages_free = int(re.search(r'Pages free:\s+(\d+)\.', raw_vm)[1])
        assert sample['actualFreeBytes'] == page * pages_free
        assert sample['pressureLevel'] == int(raw_mem.splitlines()[0]) <= 2
        used = re.search(r'used\s*=\s*([0-9.]+)([MG])', raw_mem)
        swap = Decimal(used[1]) * (1024**2 if used[2] == 'M' else 1024**3)
        assert Decimal(sample['reportedSwapBytes']) == swap
        swaps.append(swap); free.append(sample['actualFreeBytes'])
        if sample['nativeRSSBytes'] is not None:
            assert sample['nativePID'] == sample['nativePGID'] == receipt['nativePID']
            assert sample['nativeCommand'] == ' '.join(receipt['command'])
            assert type(sample['nativeRSSBytes']) is int and sample['nativeRSSBytes'] <= 1024**3
            rss.append(sample['nativeRSSBytes'])
    assert free[0] >= 1024**3 and free[1] >= 1024**3
    assert max(swaps) <= swaps[0]
    assert all(a['monotonicSeconds'] <= b['monotonicSeconds'] for a,b in zip(samples,samples[1:]))
    result = {
        'schemaVersion': 1, 'kind': 'independent_completed_constructor_evidence_review',
        'reviewScope': 'Read-only post-run CPU metadata/source/receipt replay; not a prospective oracle and no helper/native execution.',
        'historicalConstructorEvidenceConsistent': True, 'inputPins': inputs, 'archivedNativeSHA256': NATIVE,
        'archivedSourceFilesVerified': len(source_files), 'currentSourceDrift': current_source_drift,
        'gitDependencyStringsRetainedNotIndependentlyQueried': source_manifest['dependencies'],
        'listedBundleFilesVerified': len(bundle['files']), 'bundleManifestSHA256': sha(raw_bundle),
        'currentBundleExactTreeClean': not extra, 'laterBundleEntries': extra,
        'laterBundleFinding': 'Root reports a later readiness run imported artifacts.py and created __pycache__; that readiness parent retained a reference-recheck failure. Listed constructor bundle/source/native bytes remain pinned; current modified tree is not approved for reuse.',
        'rootReadinessFailureIndependentlyReplayed': False,
        'driverPins': driver_pins, 'sourceTensors': len(tensors), 'sourceTensorBytes': report['sourceTensorBytes'],
        'largestSourceTensorBytes': report['largestSourceTensorBytes'],
        'sourceDtypeCounts': dict(sorted(Counter(r['sourceDType'] for r in tensors).items())),
        'fullConstructor': full, 'stages': stages,
        'memory': {'savedSamples': len(samples), 'nativePIDAttributedSamples': len(rss), 'missingNativeRSSSamples': len(samples)-len(rss),
                   'maximumSavedRSSBytes': max(rss), 'minimumSavedVMStatFreeBytes': min(free),
                   'initialVMStatFreeBytes': free[0], 'prelaunchVMStatFreeBytes': free[1],
                   'pressureLevels': sorted(set(s['pressureLevel'] for s in samples)),
                   'reportedSwapBytesInitial': str(swaps[0]), 'reportedSwapBytesMaximum': str(max(swaps)),
                   'noIncreaseInSavedRoundedSwapReports': max(swaps) <= swaps[0], 'absoluteZeroSwap': swaps[0] == 0},
        'limits': ['Native metadata and all full/compact logical shapes/dtypes match the retained registered metadata; source offsets are bounded and nonoverlapping but payload headers/bytes were not reread by this reviewer.',
                   'Checkpoint checksum reading reported by native is distinct from tensor materialization; full/stage constructors remained lazy and report no parameter evaluation, loading or forward.',
                   'Model/file retirement and process reaping are source-backed native/parent assertions, not independent weak-reference or waitpid observations in this review.',
                   'The historical constructor screen is 1GiB initial/prelaunch free and no increase in already nonzero reported swap. It is not the selected-stage 6GiB/absolute-zero-swap gate.',
                   'Saved RSS observations are not peak memory; logical constructor bytes are not resident allocations. No load/forward/27B fit/provider/8K/performance qualification.',
                   'No model payload, new native process, compiler, SSH, subprocess, or saved helper execution performed. Original receipts and later bundle entries remain untouched.'],
    }
    destination = OUT / 'review.json'
    with destination.open('x') as stream:
        json.dump(result, stream, indent=2, sort_keys=True); stream.write('\n')
    print(json.dumps({k:result[k] for k in ('historicalConstructorEvidenceConsistent','archivedSourceFilesVerified','currentSourceDrift','listedBundleFilesVerified','currentBundleExactTreeClean','sourceTensors','sourceTensorBytes','fullConstructor','stages','memory')}))
    print(json.dumps({'reviewPath':str(destination),'reviewSHA256':file_pin(destination)['sha256']}))


if __name__ == '__main__':
    main()
