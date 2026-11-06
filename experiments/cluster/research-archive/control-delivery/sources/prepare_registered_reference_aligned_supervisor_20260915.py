"""Create one pinned supervisor derivative without launching a child or model."""
import ast
import difflib
import hashlib
import json
from pathlib import Path
import shutil
import sys

ROOT = Path(__file__).resolve().parent
BASE = ROOT / 'registered-full-generation-reference-diagnostics-supervisor-20260915'
OUT = ROOT / 'registered-full-generation-reference-aligned-payload-supervisor-20260915'
BUILD = ROOT / 'qwen-registered-generation-reference-build-20260915'
ALIGNED = ROOT / 'qwen-reference-aligned-payload-draft-20260915'
BASE_SHA = '43c4dcaaef9ec06b51379146606f664fcfebdf5c98aeaf49c0e578183dc9273c'
NATIVE = 'd71726f61ff5cef6c2a7722b0a06fb7d6b7c61af2cb081ff3aef083803f32aac'
BUILD_SHA = 'c80556866c63de8ff800cef947ea6467366bd561f6abcbdf5b73c919df30e183'
BUNDLE_SHA = '3f312fd2cc9060b9ca960f8cc200983f371d52c0b64423a4266f0cd08f1f11aa'
ALIGNED_SHA = 'e848918ae88541b071cacc137b99bbbb14ece7920694bc4c9ec6e0a94ef4a3ba'
REMOTE = '/Users/developer/DarkbloomDev/qwen-registered-generation-reference-20260915'


def pin(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1048576), b''):
            digest.update(block)
    return {'bytes': path.stat().st_size, 'sha256': digest.hexdigest()}


def save(path, value):
    path.write_text(json.dumps(value, sort_keys=True, indent=2) + '\n')


def verify_manifest(path, expected):
    assert pin(path / 'manifest.json')['sha256'] == expected
    value = json.loads((path / 'manifest.json').read_bytes())
    for row in value['files']:
        assert pin(path / row['path']) == {k: row[k] for k in ('bytes', 'sha256')}, row['path']
    return value


def constant(text, name):
    return next(node.value.value for node in ast.parse(text).body if isinstance(node, ast.Assign)
                and any(isinstance(target, ast.Name) and target.id == name for target in node.targets))


def main():
    assert not OUT.exists(), 'Never replace a frozen or partially prepared derivative'
    prior = verify_manifest(BASE, BASE_SHA)
    assert len(prior['files']) == 62
    aligned = verify_manifest(ALIGNED, ALIGNED_SHA)
    build_path = BUILD / 'build-manifest-3.json'
    bundle_directory = BUILD / 'runtime-bundle-aligned-payload'
    assert pin(build_path)['sha256'] == BUILD_SHA
    build = json.loads(build_path.read_bytes())
    assert build['binarySHA256'] == NATIVE and build['sourcePinsUnchanged'] is True
    for row in build['files']:
        assert pin(Path(row['path'])) == {k: row[k] for k in ('bytes', 'sha256')}
    assert pin(bundle_directory / 'bundle.json')['sha256'] == BUNDLE_SHA
    bundle = json.loads((bundle_directory / 'bundle.json').read_bytes())
    assert set(bundle) == {'schemaVersion', 'scope', 'sourceManifestSHA256', 'files'}
    assert bundle['schemaVersion'] == 1 and bundle['sourceManifestSHA256'] == BUILD_SHA
    expected_bundle = {'cluster-inference': NATIVE,
        'mlx.metallib': '2129f6132794d84243c02631bc7478417dba0e0dbd10467beab56c11bf20bdd2',
        'mlx-swift-lm_MLXLMCommon.bundle/pagedattention.metal': '4ad3ff17d8c6e0a3b5b8a91e9151447f84e36cb3688ed204e1e7eb6838dd9149'}
    assert len(bundle['files']) == 3 and {x['path'] for x in bundle['files']} == set(expected_bundle)
    for row in bundle['files']:
        assert row['sha256'] == expected_bundle[row['path']]
        assert pin(bundle_directory / row['path']) == {k: row[k] for k in ('bytes', 'sha256')}
    OUT.mkdir(mode=0o700)
    for row in prior['files']:
        destination = OUT / row['path']
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(BASE / row['path'], destination)
    original = (BASE / 'reference_inputs.py').read_text()
    old_native, old_source = constant(original, 'NATIVE'), constant(original, 'SOURCE')
    updated = original.replace("NATIVE = '" + old_native + "'", "NATIVE = '" + NATIVE + "'")
    updated = updated.replace("SOURCE = '" + old_source + "'", "SOURCE = '" + BUILD_SHA + "'")
    assert updated.replace(NATIVE, old_native).replace(BUILD_SHA, old_source) == original
    (OUT / 'reference_inputs.py').write_text(updated)
    old_job = json.loads((BASE / 'example-job.json').read_bytes())
    job = dict(old_job, deployment=REMOTE + '/native-aligned-payload', run_dir=REMOTE + '/runs/short-27b-4',
               native_sha256=NATIVE, source_manifest_sha256=BUILD_SHA, bundle_sha256=BUNDLE_SHA)
    changed_keys = {key for key in job if job[key] != old_job[key]}
    assert changed_keys == {'deployment', 'run_dir', 'native_sha256', 'source_manifest_sha256', 'bundle_sha256'}
    (OUT / 'example-job.json').write_text(json.dumps(job, sort_keys=True, separators=(',', ':')) + '\n')
    names = ['QwenRegisteredGenerationReferenceLoading.swift', 'QwenFullGenerationReferenceBudget.swift',
             'QwenFullGenerationReferenceCheck.swift']
    actual_source = BUILD / 'workspace/experiments/cluster/inference/Sources/ClusterInference'
    source_pins = json.loads((BASE / 'native-source-pins.json').read_bytes())
    changed_sources = []
    for name in names:
        source = ALIGNED / 'Sources' / name
        assert pin(source) == pin(actual_source / name)
        shutil.copy2(source, OUT / 'native-contract' / name)
        copied = 'native-contract/' + name
        old_rows = [row for row in source_pins if row['copy'] == copied]
        row = {'copy': copied, 'path': str(source), 'sha256': pin(source)['sha256']}
        if old_rows:
            assert len(old_rows) == 1
            source_pins[source_pins.index(old_rows[0])] = row
        else:
            source_pins.append(row)
        changed_sources.append(dict(row, actualBuildSource=str(actual_source / name), bytes=pin(source)['bytes']))
    for row in source_pins:
        assert pin(OUT / row['copy'])['sha256'] == row['sha256']
    save(OUT / 'native-source-pins.json', source_pins)
    # Preserve the prior observation-only diagnostic source exactly.
    assert pin(OUT / 'native-contract/QwenFullGenerationReferenceResources.swift')['sha256'] == 'a84eceb9547c1bb4d5dc970af61c5d8e05698fef022992d10cef6a029d6c8977'
    runtime = ['run_reference.py', 'worker_processes.py', 'worker_contract.py', 'reference_resources.py',
        'binding_common.py', 'binding_inputs.py', 'stage_checks/common.py', 'stage_checks/long_profile.py',
        'stage_checks/__init__.py', 'reference_profiles.py', 'reference_contract.py',
        'reference_completion.py', 'reference_state.py']
    for name in runtime:
        assert (OUT / name).read_bytes() == (BASE / name).read_bytes()
    tests = ['test_reference_supervisor.py', 'test_registered_reference.py', 'fabricated_reference.py']
    for name in tests:
        assert (OUT / name).read_bytes() == (BASE / name).read_bytes()
    sys.path.insert(0, str(OUT))
    from reference_inputs import Pins, validate_job, native_spec, verify_launcher
    from reference_contract import expected_identity
    validate_job(job)
    tokens = json.loads((OUT / 'request-input/prompt.ids.json').read_bytes())
    identity = expected_identity(job, tokens)
    prior_check = json.loads((BASE / 'metadata-check.json').read_bytes())
    assert identity['requestFingerprint'] == prior_check['requestFingerprint'] == '3bbb90582bfdd9a18a821d311c435be1b1894f216913e47435d4f8739ecb402d'
    assert identity['profile']['fingerprint'] == prior_check['profileFingerprint'] == '397a3ed1377b326e5e6c5614a969d1e8ffad48c789bb00f66bf99b843da83d5f'
    spec = native_spec(job)
    assert len(spec.argv) == 25 and spec.argv[0] == REMOTE + '/native-aligned-payload/cluster-inference'
    assert job['request_id'] == '20801ced-ca29-4faf-b71a-9ebbe1886a14'
    assert (job['prompt_count'], job['chunk_size'], job['output_count'], job['stage_cut'], job['stop_token_ids']) == (32, 16, 128, 32, [])
    assert (job['native_seconds'], job['parent_seconds']) == (300, 315)
    metadata = {'schema': 'registered_reference_aligned_metadata_check_v1', 'exampleJobValidated': True,
        'requestAndProfileFingerprintUnchanged': True, 'requestFingerprint': identity['requestFingerprint'],
        'profileFingerprint': identity['profile']['fingerprint'], 'nativeSHA256': NATIVE,
        'buildManifestSHA256': BUILD_SHA, 'bundleManifestSHA256': BUNDLE_SHA,
        'exampleJobSHA256': pin(OUT / 'example-job.json')['sha256'], 'exampleNativeArgv': list(spec.argv),
        'exactInheritedRuntimeCount': len(runtime), 'inputsRuntimeChangeOnlyTwoBuildConstants': True,
        'changedJobKeys': sorted(changed_keys), 'actualAlignedNativeCPUCheck': json.loads((BUILD / 'cpu-check-3/execution.json').read_bytes()),
        'supervisorBehavioralTestsReexecuted': False, 'nativeModelCompilerOrNetworkExecutedByPackaging': False}
    save(OUT / 'metadata-check.json', metadata)
    save(OUT / 'source-checks.json', dict(metadata,
        alignedSourceManifestSHA256=ALIGNED_SHA, alignedSourceManifest=aligned, alignedSources=changed_sources,
        retainedDiagnosticSourceSHA256='a84eceb9547c1bb4d5dc970af61c5d8e05698fef022992d10cef6a029d6c8977',
        exactInheritedRuntime={name: pin(OUT / name)['sha256'] for name in runtime},
        exactInheritedTests={name: pin(OUT / name)['sha256'] for name in tests},
        finalizer={'path': str(Path(__file__)), **pin(Path(__file__))},
        inheritedCPUReceiptSHA256=pin(BASE / 'cpu-check-registered-1/execution.json')['sha256']))
    save(OUT / 'lineage.json', {'schema': 'registered_reference_aligned_derivative_v1',
        'predecessor': str(BASE), 'predecessorManifestSHA256': BASE_SHA, 'predecessorManifest': prior,
        'predecessorLineage': json.loads((BASE / 'lineage.json').read_bytes()),
        'runtimeDelta': ['reference_inputs.py NATIVE/SOURCE constants only'], 'newSupervisorRuntime': [],
        'alignedSourceManifestSHA256': ALIGNED_SHA, 'alignedSources': changed_sources,
        'buildManifestPath': str(build_path), 'buildManifestSHA256': BUILD_SHA,
        'bundleManifestPath': str(bundle_directory / 'bundle.json'), 'bundleManifestSHA256': BUNDLE_SHA,
        'priorCPUCheckDirectoriesAreHistorical': True, 'unchangedSupervisorBehavioralTestsNotRepeated': True,
        'prospectiveSupervisorDeployment': REMOTE + '/supervisor-aligned-payload'})
    patch = ''
    for name in ['reference_inputs.py', 'example-job.json', 'native-contract/QwenFullGenerationReferenceBudget.swift']:
        patch += ''.join(difflib.unified_diff((BASE / name).read_text().splitlines(True), (OUT / name).read_text().splitlines(True),
                         fromfile='before/' + name, tofile='after/' + name))
    for name in ['QwenRegisteredGenerationReferenceLoading.swift', 'QwenFullGenerationReferenceCheck.swift']:
        patch += ''.join(difflib.unified_diff([], (OUT / 'native-contract' / name).read_text().splitlines(True),
                         fromfile='/dev/null', tofile='after/native-contract/' + name))
    (OUT / 'runtime.patch').write_text(patch)
    job_sha = pin(OUT / 'example-job.json')['sha256']
    readme = (BASE / 'README.md').read_text()
    for before, after in [(old_native, NATIVE), (old_source, BUILD_SHA), (old_job['bundle_sha256'], BUNDLE_SHA),
                          (pin(BASE / 'example-job.json')['sha256'], job_sha), ('native-diagnostics', 'native-aligned-payload'),
                          ('runs/short-27b-2', 'runs/short-27b-4')]:
        readme = readme.replace(before, after)
    readme = readme.replace('This derivative changes only build pins and a native resource-refusal diagnostic string.',
        'This derivative uses the existing verified-descriptor aligned payload reader for full-model loading and charges its bounded scratch while loading; the resource-refusal diagnostic string is retained.')
    readme = readme.replace('The derivative changes only model/request admission and native report bindings.',
        'The registered predecessor introduced model/request admission and native report bindings; this aligned derivative changes only the two supervisor build constants and the job paths/pins.')
    readme = readme.replace('## Diagnostic revision', '## Retained diagnostic revision')
    readme = readme.replace('Only pure job/profile/native-argv metadata checks were rerun; the 18 behavioral tests/17 fabricated children above belong to the predecessor, not this constant-only derivative.',
        'The 18 behavioral tests/17 fabricated children above belong to the registered predecessor. This package reruns only pure job/profile/native-argv and source equality checks; no unchanged supervisor behavioral test was repeated.')
    readme += ('\n## Aligned payload revision\n\n'
        'The full-model loader selects the existing aligned reader after prepared-resource admission and before payload materialization. '
        'The budget adds 8,404,992 bytes (8 MiB + 16 KiB) to required actual free memory while loading remains, releasing that allowance at completed load. '
        'Allocator requirements, six-GiB floor, model math, deadline, cleanup and report acceptance remain unchanged. '
        'The exact changed Loader/Budget/Check sources are retained in native-contract/; the prior diagnostic Resources source and patch are preserved. '
        'The actual new binary passed the metadata-only native mode with 43 accepted/86 rejected in 1.347880417 seconds; no model or forward ran. '
        'Its local vtool/otool inspection records minmacOS 26.2 and only system dynamic dependencies. '
        'Prior physical failures remain separate; this package is prospective and makes no aligned-load success or performance claim.\n\n'
        'Root deploys this entire directory to `' + REMOTE + '/supervisor-aligned-payload` and the exact four-file runtime tree to sibling `native-aligned-payload`. '
        'Use `example-job.json` without changing request/model/prompt/deadline fields and a fresh `runs/short-27b-4`; require the same resource preflight before launch.\n')
    (OUT / 'README.md').write_text(readme)
    (OUT / 'HANDOFF.md').write_text('# Registered reference aligned-payload supervisor\n\n'
        'This new package preserves diagnostics predecessor ' + BASE_SHA + ' unchanged. '
        'It uses the same 27B P32/C16/O128/cut32, UUID 20801ced-ca29-4faf-b71a-9ebbe1886a14 and empty stops, '
        'with the same arithmetic, 300-second native / 315-second parent bounds, resource guards and acceptance/cleanup code.\n\n'
        'Native SHA256: ' + NATIVE + '. Build manifest: ' + BUILD_SHA + '. Bundle manifest: ' + BUNDLE_SHA + '. '
        'Example job SHA256: ' + job_sha + '.\n\n'
        'Remote runtime: `' + REMOTE + '/native-aligned-payload`; supervisor: `' + REMOTE + '/supervisor-aligned-payload`; '
        'fresh run: `' + REMOTE + '/runs/short-27b-4`. Root alone deploys, verifies, purges and executes. '
        'The complete runtime tree is three exact files plus bundle.json. The launcher retains its existing 64-member bound.\n\n'
        'All 13 unaffected supervisor runtime files, tests, prompt/request packet and retained diagnostics source are exact copies. '
        'Only NATIVE/SOURCE constants and five job path/build fields change in the supervisor. '
        'Native aligned Loader/Budget/Check copies and their source/build pins are preserved, including the 8 MiB + 16 KiB loading scratch. '
        'No model/compiler/network work occurred during packaging; inspection executed only vtool/otool. '
        'The root-produced new native CPU receipt is 43 accepted/86 rejected; inherited supervisor tests remain attributed to their original run. '
        'A repeated resource refusal stays a failure with raw stderr, never an accepted reference.\n')
    python_count = 0
    for path in OUT.rglob('*.py'):
        ast.parse(path.read_text(), feature_version=(3, 9))
        python_count += 1
    actual = [p for p in OUT.rglob('*') if p.is_file()]
    assert len(actual) == 64 and all('__pycache__' not in p.parts for p in actual)
    for path in actual:
        assert path.stat().st_size <= 4 * 1024**2 and not path.is_symlink()
    save(OUT / 'manifest.json', {'schema': 'private_registered_reference_aligned_payload_supervisor_manifest_v1',
        'files': [{'path': str(p.relative_to(OUT)), **pin(p)} for p in sorted(actual)],
        'predecessorManifestSHA256': BASE_SHA, 'nativeModelCompilerOrNetworkExecutedByPackaging': False,
        'supervisorBehavioralTestsReexecuted': False, 'inheritedBehavioralTestsPassed': 18,
        'inheritedActualFabricatedPythonChildren': 17, 'nativeMetadataCheckAccepted': 43, 'nativeMetadataCheckRejected': 86,
        'python39SyntaxFiles': python_count, 'independentSourceReview': 'pending at freeze'})
    pins = Pins()
    verify_launcher(OUT, pin(OUT / 'manifest.json')['sha256'], pins)
    pins.recheck()
    verify_manifest(BASE, BASE_SHA)
    print(json.dumps({'directory': str(OUT), 'manifest': pin(OUT / 'manifest.json'), 'members': len(actual),
        'job': pin(OUT / 'example-job.json'), 'requestFingerprint': identity['requestFingerprint'],
        'profileFingerprint': identity['profile']['fingerprint'], 'python39SyntaxFiles': python_count,
        'actualFrozenLauncherVerificationPassed': True,
        'launchArgv': ['/usr/bin/python3', '-B', REMOTE + '/supervisor-aligned-payload/run_reference.py',
                       '--job', REMOTE + '/supervisor-aligned-payload/example-job.json', '--job-sha256', job_sha,
                       '--launcher-sha256', pin(OUT / 'manifest.json')['sha256']]}, indent=2))


if __name__ == '__main__':
    main()
