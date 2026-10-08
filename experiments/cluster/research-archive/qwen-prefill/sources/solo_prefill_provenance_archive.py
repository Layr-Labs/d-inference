"""Read-only archive and staged-input binding; never executes launcher modules."""
import ast
import hashlib
import json
from pathlib import Path
import re
from types import SimpleNamespace
from solo_prefill_provenance_records import (ARTIFACT, BASELINE_EVIDENCE, BINARY, CONFIGURATION,
    EXPECTED_INVENTORY, ORIGIN_RECEIPT, ORIGIN_REFERENCE, expected_rank, reference_bytes)

ROOT = Path(__file__).resolve().parent
PRIOR = ROOT / 'audit-qwen-layer-stage-ranks-20260914.py'
PRIOR_SHA = 'edcffd2d35f9ab95e16ffac72da45dc7a69150c99f4bed47b821bd848921c83e'
RESOURCE_HELPER = ROOT / 'remote_prefill_provenance_records.py'
RESOURCE_HELPER_SHA = '7c1b2119eedb067fe56a8290f4a63ac04efb474c5cf6981b30f04767deccc1a8'
LAUNCHER_REVIEW = ROOT / 'remote-solo-prefill-launcher-draft/source-review-20260914.json'
LAUNCHER_REVIEW_SHA = '78eced9b5fe83e68d084e9b02d3264d18aa02a148aba8d904baad24ef5eb163a'


def pure_helpers():
    if hashlib.sha256(PRIOR.read_bytes()).hexdigest() != PRIOR_SHA:
        raise ValueError('Prior pure helper source pin differs')
    if hashlib.sha256(RESOURCE_HELPER.read_bytes()).hexdigest() != RESOURCE_HELPER_SHA:
        raise ValueError('Resource helper pin differs')
    tree = ast.parse(PRIOR.read_text(), filename=str(PRIOR))
    names = {'sha', 'require', 'read', 'files'}
    nodes = [n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name in names]
    if {n.name for n in nodes} != names:
        raise ValueError('Prior pure helper inventory differs')
    namespace = dict(hashlib=hashlib, json=json, Path=Path)
    exec(compile(ast.Module(body=nodes, type_ignores=[]), str(PRIOR), 'exec'), namespace)
    return SimpleNamespace(**{name: namespace[name] for name in names})


def archive_files(h, base, entries):
    for entry in entries:
        path = base / entry['path']
        h.require(path.resolve(strict=True).is_relative_to(base.resolve()), 'Archive file escaped its root')
    return h.files(base, entries)


def provenance(run, receipt, tests, h):
    require, read, sha = h.require, h.read, h.sha
    require(tests['kind'] == 'remote_solo_prefill_launcher_source_review' and tests['cpu_tests_passed'] is True
            and type(tests['prospective_cpu_tests']) is int and tests['prospective_cpu_tests'] == 36
            and tests['native_execution_performed'] is False and tests['ssh_performed'] is False
            and tests['gpu_execution_performed'] is False, 'Frozen fake-test status differs')
    require(sha(run / 'source-manifest.json') == receipt['source_manifest_sha256'], 'Source manifest differs')
    source = read(run / 'source-manifest.json')
    source_files = archive_files(h, run / 'source', source['files'])
    require(type(receipt['source_file_count']) is int and 1 <= len(source_files) == receipt['source_file_count'] <= 1024,
            'Frozen source count differs')
    dependencies = source['dependencies']
    require(dependencies['tracked_dependency_changes'] == ''
            and re.fullmatch('[0-9a-f]{40}', dependencies['repository_head']), 'Source dependency attestation differs')
    for line in dependencies['submodules'].splitlines():
        require(re.match(r'^\s*[0-9a-f]{40}\s+\S+', line), 'Submodule identity malformed')
    require(sha(run / 'bundle/bundle.json') == receipt['bundle_manifest_sha256'], 'Bundle manifest differs')
    bundle = archive_files(h, run / 'bundle', read(run / 'bundle/bundle.json')['files'])
    bundle_map = {entry['path']: entry['sha256'] for entry in bundle}
    require(bundle_map['cluster-inference'] == BINARY, 'Native binary differs')
    for name in ('rank_worker.py', 'artifacts.py'):
        require(bundle_map[name] == sha(run / 'source/experiments/cluster/runtime' / name), 'Bundle runtime differs from source')
    launcher = archive_files(h, run / 'launcher', receipt['launcher_files'])
    tested = {entry['path']: entry['sha256'] for entry in tests['files'] if entry['path'].endswith('.py')}
    require(len(tested) == len([x for x in tests['files'] if x['path'].endswith('.py')])
            and {entry['path']: entry['sha256'] for entry in launcher} == tested, 'Archived launcher differs from tested draft')
    require(sha(run / 'controls/control-manifest.json') == receipt['control_manifest_sha256'], 'Control manifest differs')
    controls = archive_files(h, run / 'controls', read(run / 'controls/control-manifest.json')['files'])
    require({entry['path'] for entry in controls} == {'remote_prefill_control.py', 'prefill_compute_memory.py',
            'artifacts.py', 'control-config.json'}, 'Pinned control inventory differs')
    for name in ('remote_prefill_control.py', 'prefill_compute_memory.py'):
        require(sha(run / 'controls' / name) == tested[name], 'Staged control source differs')
    require(sha(run / 'controls/artifacts.py') == bundle_map['artifacts.py'], 'Control artifact verifier differs')
    native = archive_files(h, run, receipt['native_files'])
    require({entry['path'] for entry in native} == {'native/rank.json', 'native/stdout.jsonl', 'native/stderr.log'}
            and (run / 'native/stderr.log').stat().st_size == 0, 'Native output inventory/stderr differs')
    inputs = archive_files(h, run, receipt['inputs']['files'])
    require({x['path'] for x in inputs} == {'inputs/origin-receipt.json', 'inputs/origin-prompt-65.json',
            'inputs/origin-prompt-96.json', 'inputs/source-text.txt', 'inputs/expected-inventory.json',
            'inputs/prompt.json', 'inputs/solo-reference.origin.json', 'inputs/solo-reference.staged.json'}, 'Input inventory differs')
    metadata = archive_files(h, run, receipt['retrieved_remote_metadata'])
    require({x['path'] for x in metadata} == {'remote-metadata/' + name for name in ('before-config.json',
            'before-manifest.json', 'after-config.json', 'after-manifest.json', 'rank.final.json',
            'prompt.final.json', 'solo-reference.final.json')}, 'Retrieved metadata inventory differs')
    return dict(source=source_files, bundle=bundle, launcher=launcher, controls=controls,
                native=native, inputs=inputs, metadata=metadata, dependencies=dependencies), bundle_map


def workload_and_controls(run, receipt, bundle_map, h):
    require, read, sha = h.require, h.read, h.sha
    require(receipt['artifact_aggregate_sha256'] == ARTIFACT
            and receipt['configuration_sha256'] == CONFIGURATION, 'Fixed artifact/configuration differs')
    prompt, remote = receipt['inputs']['prompt'], receipt['remote_paths']
    require(len(prompt) == 65 and all(type(x) is int and 0 <= x < 248320 for x in prompt)
            and receipt['inputs']['teacher'] == [] and read(run / 'inputs/prompt.json') == prompt, 'Fixed request differs')
    require(sha(run / 'inputs/origin-receipt.json') == ORIGIN_RECEIPT
            and sha(run / 'inputs/expected-inventory.json') == EXPECTED_INVENTORY, 'Original input/inventory pins differ')
    origin = read(run / 'inputs/origin-receipt.json')
    require(prompt == read(run / 'inputs/origin-prompt-65.json') == read(run / 'inputs/origin-prompt-96.json')[:65]
            == origin['tokenization']['prompt_ids'][:65]
            and sha(run / 'inputs/source-text.txt') == origin['tokenization']['source_text_sha256'], 'Prose-token provenance differs')
    reference = receipt['reference']
    require((run / 'inputs/solo-reference.origin.json').stat().st_size <= 128 * 1024, 'Origin reference exceeds bound')
    ordered, staged, staged_hash = reference_bytes((run / 'inputs/solo-reference.origin.json').read_bytes(),
        read(run / 'inputs/solo-reference.origin.json'), prompt, reference)
    require((run / 'inputs/solo-reference.staged.json').read_bytes()
            == (run / 'remote-metadata/solo-reference.final.json').read_bytes() == staged, 'Exact reference bytes differ')
    reference_files = archive_files(h, run, reference['files'])
    require(reference_files == [x for x in receipt['inputs']['files'] if x['path'].startswith('inputs/solo-reference.')],
            'Reference file inventories differ')
    rank = read(run / 'native/rank.json')
    require(rank == read(run / 'remote-metadata/rank.final.json') == expected_rank(receipt, ordered, staged_hash)
            and sha(run / 'native/rank.json') == sha(run / 'remote-metadata/rank.final.json')
            == receipt['rank_configuration_sha256'], 'Exact rank configuration differs')
    require(json.dumps(rank['input_files']['solo-reference.json'], allow_nan=False).encode('ascii') == staged,
            'Rank-worker reference byte serialization differs')
    prompt_hash = hashlib.sha256(json.dumps(prompt).encode()).hexdigest()
    require(sha(run / 'remote-metadata/prompt.final.json') == prompt_hash, 'Remote token bytes differ')
    config = read(run / 'controls/control-config.json')
    require(config == dict(remote, run_id=receipt['run_id'], bundle_sha256=receipt['bundle_manifest_sha256'],
        binary_sha256=BINARY, rank_sha256=receipt['rank_configuration_sha256'], artifact_sha256=ARTIFACT,
        configuration_sha256=CONFIGURATION, prompt_sha256=prompt_hash, solo_reference_sha256=staged_hash),
        'Pinned control configuration differs')
    for phase in ('before', 'after'):
        record = receipt['remote_' + phase]
        require(record['artifact_aggregate_sha256'] == ARTIFACT
                and record['bundle_manifest_sha256'] == receipt['bundle_manifest_sha256']
                and record['bundle_file_sha256'] == bundle_map
                and record['rank_configuration_sha256'] == receipt['rank_configuration_sha256'], 'Remote verification attestation differs')
        for name in ('config.json', 'manifest.json'):
            item, local = record['model_metadata'][name], run / 'remote-metadata' / (phase + '-' + name)
            require(item['sha256'] == sha(local) and item['size_bytes'] == local.stat().st_size
                    and item['remote_path'] == remote['run'] + '/metadata/' + phase + '-' + name,
                    'Copied remote metadata attestation differs')
    require(receipt['remote_after']['prompt_sha256'] == prompt_hash
            and receipt['remote_after']['solo_reference_sha256'] == staged_hash, 'Remote postflight input attestation differs')
    for name in ('config.json', 'manifest.json'):
        require(sha(run / 'remote-metadata' / ('before-' + name))
                == sha(run / 'remote-metadata' / ('after-' + name)), 'Remote model metadata changed')
    require(sha(run / 'remote-metadata/before-config.json') == CONFIGURATION, 'Remote config differs from pin')
    manifest = read(run / 'remote-metadata/before-manifest.json')
    listed = {entry['path']: entry for entry in manifest['files']}
    aggregate = hashlib.sha256(b''.join(bytes.fromhex(listed[name]['sha256']) for name in sorted(listed))).hexdigest()
    require(len(listed) == len(manifest['files']) == manifest['file_count']
            and sum(entry['size_bytes'] for entry in listed.values()) == manifest['total_size_bytes'] == 6113952230
            and aggregate == manifest['aggregate_sha256'] == ARTIFACT, 'Retained manifest declaration differs')
    require(0 < (run / 'native/stdout.jsonl').stat().st_size <= 64 * 1024**2, 'Native stdout exceeds bound')
    raw = (run / 'native/stdout.jsonl').read_bytes()
    lines = raw.splitlines()
    require(len(raw) <= 64 * 1024**2 and raw.endswith(b'\n') and len(lines) == 2
            and all(0 < len(line) <= 60 * 1024**2 for line in lines), 'Expected bounded two-record native output')
    return dict(exactNativeConfigurationVerified=True, nativeOutputFramingRecords=2, nativeOutputJSONParsed=False,
        originReferenceSHA256=ORIGIN_REFERENCE, stagedReferenceSHA256=staged_hash,
        baselineEvidenceFingerprint=BASELINE_EVIDENCE, threeReferenceArgumentsExact=True,
        independentReferenceSerializationReplay=True, remoteFinalReferenceBytesExact=True,
        numericalComparisonIndependentlyVerified=False, declaredArtifactPayloadBytes=manifest['total_size_bytes'],
        remoteFullArtifactBeforeAfterAttestationsMatch=True, modelPayloadIndependentlyRehashed=False,
        stdoutSHA256=sha(run / 'native/stdout.jsonl'))
