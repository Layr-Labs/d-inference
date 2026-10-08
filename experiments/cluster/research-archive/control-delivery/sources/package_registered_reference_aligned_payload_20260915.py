"""Package an already completed aligned-reader build; never execute the native file."""
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess

RESEARCH = Path(__file__).resolve().parent
ROOT = RESEARCH / 'qwen-registered-generation-reference-build-20260915'
WORK = ROOT / 'workspace'
PACKAGE = WORK / 'experiments/cluster/inference'
NATIVE = 'd71726f61ff5cef6c2a7722b0a06fb7d6b7c61af2cb081ff3aef083803f32aac'
SNAPSHOT = '0e23a3d2e1a5ec9f871219a6d67e43e8bf06a0270fe8eea638a7d8743b1ee03d'
ALIGNED = RESEARCH / 'qwen-reference-aligned-payload-draft-20260915'
ALIGNED_SHA = 'e848918ae88541b071cacc137b99bbbb14ece7920694bc4c9ec6e0a94ef4a3ba'


def pin(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1048576), b''):
            h.update(block)
    return {'bytes': path.stat().st_size, 'sha256': h.hexdigest()}


def save(path, value):
    with path.open('x') as stream:
        stream.write(json.dumps(value, indent=2, sort_keys=True) + '\n')


def members(path, wanted):
    assert pin(path / 'manifest.json')['sha256'] == wanted
    manifest = json.loads((path / 'manifest.json').read_bytes())
    for row in manifest['files']:
        assert pin(path / row['path']) == {k: row[k] for k in ('bytes', 'sha256')}, row['path']


def main():
    destination = ROOT / 'runtime-bundle-aligned-payload'
    final = ROOT / 'build-manifest-3.json'
    assert not destination.exists() and not final.exists(), 'Preserve frozen packages'
    binary = PACKAGE / '.build/arm64-apple-macosx/release/cluster-inference'
    assert pin(binary)['sha256'] == NATIVE
    assert pin(ROOT / 'source-snapshot-3.json')['sha256'] == SNAPSHOT
    members(ALIGNED, ALIGNED_SHA)
    snapshots = [(ROOT / 'source-snapshot-3.json', WORK, 3281),
                 (ROOT / 'build-3/dependency-inputs.json', PACKAGE / '.build/checkouts', 9502)]
    for snapshot, base, count in snapshots:
        values = json.loads(snapshot.read_bytes())
        assert len(values) == count
        for name, expected in values.items():
            assert pin(base / name)['sha256'] == expected, name
    assert (ROOT / 'build-3/dependency-inputs.json').read_bytes() == (ROOT / 'cpu-check-3/dependency-inputs.json').read_bytes()
    for label in ('build-3', 'cpu-check-3'):
        receipt = json.loads((ROOT / label / 'execution.json').read_bytes())
        assert receipt['exitCode'] == 0 and receipt['timedOut'] is False and receipt['interruption'] is None
        assert receipt['binarySHA256'] == NATIVE and receipt['sourceSnapshotSHA256'] == SNAPSHOT
        assert receipt['sourcePinsUnchanged'] is True and receipt['sourceCount'] == 3281 and receipt['dependencySourceCount'] == 9502
        assert receipt['modelExecuted'] is False and receipt['remoteOperations'] is False
        for stream in ('stdout', 'stderr'):
            assert pin(ROOT / label / stream)['sha256'] == receipt[stream + 'SHA256']
    cpu = json.loads((ROOT / 'cpu-check-3/stdout').read_bytes())
    assert cpu == {'accepted': 43, 'rejected': 86, 'actualAllocatorOrLiveResourceAdmissionPerformed': False,
                   'cpuOnly': True, 'kind': 'qwen_full_generation_reference_entry_check', 'modelOrNativeForwardExecuted': False}
    assert (ROOT / 'cpu-check-3/stderr').read_bytes() == b''
    inspections = []
    for label, command in [('vtool', ['/usr/bin/xcrun', 'vtool', '-show-build', str(binary)]),
                           ('otool', ['/usr/bin/otool', '-L', str(binary)])]:
        value = subprocess.run(command, capture_output=True, timeout=15, check=True)
        assert value.stderr == b''
        for stream, raw in [('stdout', value.stdout), ('stderr', value.stderr)]:
            with (ROOT / 'build-3' / ('binary-' + label + '.' + stream)).open('xb') as out:
                out.write(raw)
        inspections.append({'argv': command, 'exitCode': value.returncode})
        if label == 'vtool':
            text = value.stdout.decode()
            assert re.findall(r'\bminos\s+(\S+)', text) == ['26.2']
            assert re.findall(r'\bplatform\s+(\S+)', text) == ['MACOS']
        else:
            links = [line.strip().split(' (', 1)[0] for line in value.stdout.decode().splitlines()[1:]]
            assert links and all(p.startswith(('/usr/lib/', '/System/Library/', '/Library/Apple/System/Library/')) for p in links), links
    changed = []
    for name in ['QwenRegisteredGenerationReferenceLoading.swift', 'QwenFullGenerationReferenceBudget.swift',
                 'QwenFullGenerationReferenceCheck.swift']:
        source = ALIGNED / 'Sources' / name
        actual = PACKAGE / 'Sources/ClusterInference' / name
        assert pin(actual) == pin(source)
        changed.append({'path': str(actual), **pin(actual)})
    checks = {'schema': 'registered_reference_aligned_packaging_check_v1', 'nativeSHA256': NATIVE,
              'sourceSnapshotSHA256': SNAPSHOT, 'sourcePinsRechecked': 3281, 'dependencyPinsRechecked': 9502,
              'binaryInspection': inspections, 'minimumMacOS': '26.2', 'onlySystemDynamicDependencies': True,
              'alignedSourceManifestSHA256': ALIGNED_SHA, 'alignedSources': changed,
              'cpuCheck': cpu, 'compilerOrNativeExecutedByPackaging': False, 'remoteOperations': False,
              'packagingRecipe': {'path': str(Path(__file__)), **pin(Path(__file__))}}
    save(ROOT / 'build-3/packaging-check.json', checks)
    paths = [ROOT / 'source-snapshot-3.json', ROOT / 'build_check_aligned_payload.py', ROOT / 'build-manifest-2.json',
             ALIGNED / 'manifest.json', RESEARCH / 'qwen-reference-aligned-payload-review-20260915/source-review.json']
    for label in ['build-3', 'cpu-check-3']:
        paths += [ROOT / label / name for name in ['dependency-inputs.json', 'execution.json', 'started.json', 'stdout', 'stderr']]
    paths += [ROOT / 'build-3' / ('binary-' + label + '.' + stream)
              for label in ['vtool', 'otool'] for stream in ['stdout', 'stderr']]
    paths += [ROOT / 'build-3/packaging-check.json', Path(__file__)]
    save(final, {'schema': 'registered_full_generation_reference_aligned_payload_build_v1',
                 'scope': 'Existing verified-descriptor aligned payload reader plus its bounded host scratch allowance during full-model loading; prior resource diagnostics retained. Model arithmetic, resource floors, allocator limits and lifecycle are unchanged.',
                 'binarySHA256': NATIVE, 'sourceSnapshotSHA256': SNAPSHOT, 'sourceCount': 3281,
                 'dependencySourceCount': 9502, 'sourcePinsUnchanged': True, 'nativeModelExecuted': False,
                 'cpuChecks': 'Actual compiled metadata mode passed 43 accepted / 86 rejected in 1.347880417 seconds; no model or native forward.',
                 'minimumMacOS': '26.2', 'files': [{'path': str(p), **pin(p)} for p in paths]})
    old = ROOT / 'runtime-bundle-diagnostics'
    assert pin(old / 'bundle.json')['sha256'] == '31edaba87f91f72ab22a1ff1c1ad94842d2c3cc3129a1b4a0ea91382b6f1bdec'
    old_bundle = json.loads((old / 'bundle.json').read_bytes())
    for row in old_bundle['files']:
        assert pin(old / row['path']) == {k: row[k] for k in ('bytes', 'sha256')}
    destination.mkdir(mode=0o700)
    rows = []
    for row in old_bundle['files']:
        source = binary if row['path'] == 'cluster-inference' else old / row['path']
        output = destination / row['path']
        output.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, output)
        assert pin(output) == pin(source)
        rows.append({'path': row['path'], **pin(output)})
    save(destination / 'bundle.json', {'schemaVersion': 1,
        'scope': 'Private registered 9B/27B full reference with verified aligned payload reads and bounded loading scratch; resource diagnostics retained.',
        'sourceManifestSHA256': pin(final)['sha256'], 'files': rows})
    assert pin(binary)['sha256'] == NATIVE
    print(json.dumps({'buildManifest': {'path': str(final), **pin(final)},
                      'bundleManifest': {'path': str(destination / 'bundle.json'), **pin(destination / 'bundle.json')},
                      'binary': rows[0], 'minimumMacOS': '26.2'}, indent=2))


if __name__ == '__main__':
    main()
