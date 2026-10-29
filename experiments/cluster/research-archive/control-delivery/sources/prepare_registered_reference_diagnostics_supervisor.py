"""Finalize a private observation-only supervisor derivative from actual build pins."""
import argparse
import ast
import difflib
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parent
BASE = ROOT / 'registered-full-generation-reference-supervisor-draft-20260915'
OUT = ROOT / 'registered-full-generation-reference-diagnostics-supervisor-20260915'
DIAGNOSTIC = ROOT / 'qwen-full-reference-resource-diagnostics-20260915'
BASE_SHA = '39cd3e56d95ab152362f7f060ce6311c8f51e221fd737e3cb2e2fa8d401b7dac'
METALLIB = '2129f6132794d84243c02631bc7478417dba0e0dbd10467beab56c11bf20bdd2'
PAGED = '4ad3ff17d8c6e0a3b5b8a91e9151447f84e36cb3688ed204e1e7eb6838dd9149'

def pin(path):
    checksum = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1_048_576), b''): checksum.update(chunk)
    return dict(bytes=path.stat().st_size, sha256=checksum.hexdigest())

def save(path, value):
    path.write_text(json.dumps(value, sort_keys=True, indent=2) + '\n')

def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('--build-manifest', type=Path, required=True)
    parser.add_argument('--bundle-directory', type=Path, required=True)
    parser.add_argument('--expected-native-sha256', required=True)
    args = parser.parse_args()
    assert not (OUT / 'manifest.json').exists(), 'Never rewrite a frozen derivative'
    assert pin(BASE / 'manifest.json')['sha256'] == BASE_SHA
    baseline = json.loads((BASE / 'manifest.json').read_bytes())
    for entry in baseline['files']:
        assert pin(BASE / entry['path']) == {key: entry[key] for key in ('bytes', 'sha256')}
    build = json.loads(args.build_manifest.read_bytes())
    source_sha = pin(args.build_manifest)['sha256']
    native_sha = args.expected_native_sha256
    assert len(native_sha) == 64 and all(x in '0123456789abcdef' for x in native_sha)
    assert build['binarySHA256'] == native_sha and build['sourcePinsUnchanged'] is True
    bundle_path = args.bundle_directory / 'bundle.json'
    bundle = json.loads(bundle_path.read_bytes())
    assert set(bundle) == {'schemaVersion', 'scope', 'sourceManifestSHA256', 'files'}
    assert bundle['schemaVersion'] == 1 and bundle['sourceManifestSHA256'] == source_sha
    expected = {'cluster-inference': native_sha, 'mlx.metallib': METALLIB,
                'mlx-swift-lm_MLXLMCommon.bundle/pagedattention.metal': PAGED}
    assert len(bundle['files']) == len(expected) and {entry['path'] for entry in bundle['files']} == set(expected)
    for entry in bundle['files']:
        assert entry['sha256'] == expected[entry['path']]
        assert pin(args.bundle_directory / entry['path']) == {key: entry[key] for key in ('bytes', 'sha256')}
    bundle_sha = pin(bundle_path)['sha256']
    original_inputs = (BASE / 'reference_inputs.py').read_text()
    def constant(text, name):
        return next(node.value.value for node in ast.parse(text).body if isinstance(node, ast.Assign)
                    and any(isinstance(t, ast.Name) and t.id == name for t in node.targets))
    old_native, old_source = constant(original_inputs, 'NATIVE'), constant(original_inputs, 'SOURCE')
    assert native_sha != old_native and source_sha != old_source
    updated = original_inputs.replace("NATIVE = '" + old_native + "'", "NATIVE = '" + native_sha + "'")
    updated = updated.replace("SOURCE = '" + old_source + "'", "SOURCE = '" + source_sha + "'")
    assert updated.replace(native_sha, old_native).replace(source_sha, old_source) == original_inputs
    (OUT / 'reference_inputs.py').write_text(updated)
    job = json.loads((BASE / 'example-job.json').read_bytes())
    job.update(deployment='/Users/developer/DarkbloomDev/qwen-registered-generation-reference-20260915/native-diagnostics',
               run_dir='/Users/developer/DarkbloomDev/qwen-registered-generation-reference-20260915/runs/short-27b-2',
               native_sha256=native_sha, source_manifest_sha256=source_sha, bundle_sha256=bundle_sha)
    (OUT / 'example-job.awaiting-pins.json').rename(OUT / 'example-job.json')
    (OUT / 'example-job.json').write_text(json.dumps(job, sort_keys=True, separators=(',', ':')) + '\n')
    source_pins = json.loads((BASE / 'native-source-pins.json').read_bytes())
    diagnostic_source = DIAGNOSTIC / 'QwenFullGenerationReferenceResources.swift'
    assert pin(diagnostic_source)['sha256'] == 'a84eceb9547c1bb4d5dc970af61c5d8e05698fef022992d10cef6a029d6c8977'
    assert (OUT / 'native-contract/QwenFullGenerationReferenceResources.swift').read_bytes() == diagnostic_source.read_bytes()
    assert (DIAGNOSTIC / 'original.swift').read_bytes() == (BASE / 'native-contract/QwenFullGenerationReferenceResources.swift').read_bytes()
    for entry in source_pins:
        if entry['copy'] == 'native-contract/QwenFullGenerationReferenceResources.swift':
            entry.update(path=str(diagnostic_source), sha256=pin(diagnostic_source)['sha256'])
    save(OUT / 'native-source-pins.json', source_pins)
    runtime_names = ['run_reference.py','worker_processes.py','worker_contract.py','reference_resources.py',
        'binding_common.py','binding_inputs.py','stage_checks/common.py','stage_checks/long_profile.py',
        'stage_checks/__init__.py','reference_profiles.py','reference_contract.py','reference_completion.py','reference_state.py']
    for name in runtime_names: assert (OUT / name).read_bytes() == (BASE / name).read_bytes()
    sys.path.insert(0, str(OUT))
    from reference_inputs import validate_job, native_spec
    from reference_contract import expected_identity
    validate_job(job)
    tokens = json.loads((OUT / 'request-input/prompt.ids.json').read_bytes())
    identity = expected_identity(job, tokens)
    original_check = json.loads((BASE / 'source-checks.json').read_bytes())
    assert identity['requestFingerprint'] == original_check['requestFingerprint']
    assert identity['profile']['fingerprint'] == original_check['profileFingerprint']
    spec = native_spec(job)  # Pure value construction only; never starts a child.
    metadata = dict(schema='registered_reference_diagnostic_metadata_check_v1', exactInheritedRuntimeCount=13,
        inputsRuntimeChangeOnlyTwoBuildConstants=True, exampleJobValidated=True,
        requestAndProfileFingerprintUnchanged=True, requestFingerprint=identity['requestFingerprint'],
        profileFingerprint=identity['profile']['fingerprint'], exampleNativeArgv=list(spec.argv),
        behavioralTestsReexecuted=False, nativeModelCompilerOrNetworkExecuted=False,
        nativeSHA256=native_sha, buildManifestSHA256=source_sha, bundleManifestSHA256=bundle_sha,
        exampleJobSHA256=pin(OUT / 'example-job.json')['sha256'])
    save(OUT / 'metadata-check.json', metadata)
    save(OUT / 'source-checks.json', dict(metadata, diagnosticSource=pin(diagnostic_source),
        diagnosticPatch=pin(DIAGNOSTIC / 'diagnostics.patch'), finalizer=pin(Path(__file__)),
        inheritedCPUReceiptSHA256=pin(BASE / 'cpu-check-registered-1/execution.json')['sha256']))
    save(OUT / 'lineage.json', dict(schema='registered_reference_diagnostic_derivative_v1',
        predecessor=str(BASE), predecessorManifestSHA256=BASE_SHA,
        exactInheritedRuntime={name:pin(OUT/name)['sha256'] for name in runtime_names},
        runtimeDelta=['reference_inputs.py build constants only'], newRuntime=[],
        buildManifestPath=str(args.build_manifest), buildManifestSHA256=source_sha,
        bundleManifestPath=str(bundle_path), bundleManifestSHA256=bundle_sha,
        diagnosticSourceManifest=pin(DIAGNOSTIC / 'manifest.json'),
        priorCPUCheckDirectoriesAreHistorical=True, unchangedBehavioralTestsNotRepeated=True))
    patch = ''
    for name in ['reference_inputs.py','example-job.json','native-contract/QwenFullGenerationReferenceResources.swift']:
        patch += ''.join(difflib.unified_diff((BASE/name).read_text().splitlines(True), (OUT/name).read_text().splitlines(True),
            fromfile='before/'+name, tofile='after/'+name))
    (OUT / 'runtime.patch').write_text(patch)
    readme = (BASE / 'README.md').read_text().replace(old_native,native_sha).replace(old_source,source_sha)
    old_job=json.loads((BASE/'example-job.json').read_bytes())
    readme=readme.replace(old_job['bundle_sha256'],bundle_sha).replace(pin(BASE/'example-job.json')['sha256'],pin(OUT/'example-job.json')['sha256'])
    readme=readme.replace('runs/short-27b-1','runs/short-27b-2').replace('`runs/short-27b-1`','`runs/short-27b-2`')
    readme=readme.replace('/qwen-registered-generation-reference-20260915/native`','/qwen-registered-generation-reference-20260915/native-diagnostics`')
    readme=readme.replace('The parent has been exercised only with fabricated Python children; no model or network was run by this author.',
        'This derivative changes only build pins and a native resource-refusal diagnostic string. It has not executed a model or network request. The earlier physical failure remains separate; no resource guard is weakened.')
    readme += '\n## Diagnostic revision\n\nThe native refusal now includes authorized tensor progress, load/request flags, actual/required free bytes, physical memory, allocator limit/requirement, active bytes and cache bytes. Its comparisons, reservations, model arithmetic and accepted JSON contracts remain unchanged. The 13 unaffected supervisor runtime files and all behavioral test bodies are byte-identical to the registered predecessor. Only pure job/profile/native-argv metadata checks were rerun; the 18 behavioral tests/17 fabricated children above belong to the predecessor, not this constant-only derivative.\n'
    (OUT/'README.md').write_text(readme)
    (OUT/'HANDOFF.md').write_text('# Registered reference diagnostic supervisor\n\n'
        'This separate package keeps predecessor 39cd3e56 frozen and preserves the same 27B P32/C16/O128/cut32 request, UUID and stops. '
        'It targets the new native-diagnostics directory and fresh runs/short-27b-2. Only native refusal text and the corresponding build/job pins change. '
        'All guards, ownership cleanup, completion/state checks and false numerical/performance claims remain unchanged.\n\n'
        f'Native SHA256: {native_sha}. Build manifest: {source_sha}. Bundle manifest: {bundle_sha}. '
        f'Example job SHA256: {pin(OUT/"example-job.json")["sha256"]}.\n\n'
        'Root uses the README command with this directory manifest hash after deployment verification. The Python parent reports failure and preserves native stderr if the refusal repeats; it never accepts a resource error. '
        'No behavioral tests were repeated solely for pin changes. metadata-check.json records pure job/profile/argv checks and unchanged fingerprints; source-checks.json records 13 exact runtime files and the two-constant inverse. No native/model/compiler/network execution was performed by this task.\n')
    for file in OUT.rglob('*.py'): ast.parse(file.read_text(), feature_version=(3,9))
    members=[]
    for file in sorted(OUT.rglob('*')):
        if file.is_file() and '__pycache__' not in file.parts and file != OUT/'manifest.json':
            members.append(dict(path=str(file.relative_to(OUT)), **pin(file)))
    assert len(members)<=64, 'Preserve unchanged launcher member bound'
    save(OUT/'manifest.json', dict(schema='private_registered_reference_diagnostics_supervisor_manifest_v1',
        files=members, nativeModelCompilerOrNetworkExecuted=False, behavioralTestsReexecuted=False,
        inheritedBehavioralTestsPassed=18, inheritedActualFabricatedPythonChildren=17,
        predecessorManifestSHA256=BASE_SHA, independentSourceReview='pending at freeze'))
    print(json.dumps(dict(directory=str(OUT),manifest=pin(OUT/'manifest.json'),members=len(members),
                         job=pin(OUT/'example-job.json'),metadata=metadata),indent=2))

if __name__=='__main__': main()
