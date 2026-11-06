#!/usr/bin/env python3
"""CPU-only provenance audit; numerical oracle and remote execution are separate."""
import argparse
import ast
from datetime import datetime, timezone
import hashlib
import importlib
import json
from pathlib import Path
import re
import sys
from types import SimpleNamespace
from remote_prefill_provenance_records import controls_sequence, memory_values, utc, validate_resources
sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parent
PRIOR = ROOT / 'audit-qwen-layer-stage-ranks-20260914.py'
PRIOR_SHA = 'edcffd2d35f9ab95e16ffac72da45dc7a69150c99f4bed47b821bd848921c83e'
TESTS = ROOT / 'remote-prefill-launcher-draft/draft-cpu-check-receipt.json'
TESTS_SHA = '490335242fa911babfba02a9dbde5ba14b1706a60abfeb64605de283b4913faf'
RECEIPT_SHA = '74065cafc7e9341707dc25cd1e90b3ccc5ed65c8a47ffa77712ceeaf889ff752'
POSTFLIGHT_SHA = 'b22e0f11b772f993f4d95aa3a3b134d14e16f982e14fcb2d7061b397c4651678'
BINARY_SHA = '48931adacab531e289063dbe3f5a03871ee3fd420f3767be82024e7699d74f46'


def pure_helpers():
    # Execute only the four established, read-only helper definitions. The
    # historical script's main(), imports, paths, and artifact audit do not run.
    assert hashlib.sha256(PRIOR.read_bytes()).hexdigest() == PRIOR_SHA, 'Prior pure helper source pin differs'
    tree = ast.parse(PRIOR.read_text(), filename=str(PRIOR))
    names = {'sha', 'require', 'read', 'files'}
    nodes = [node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name in names]
    assert {node.name for node in nodes} == names
    space = dict(hashlib=hashlib, json=json, Path=Path)
    exec(compile(ast.Module(body=nodes, type_ignores=[]), str(PRIOR), 'exec'), space)
    return SimpleNamespace(**{name: space[name] for name in names})


def archive_files(helper, base, entries):
    for entry in entries:
        path = base / entry['path']
        helper.require(path.resolve(strict=True).is_relative_to(base.resolve()), 'Archive file escaped its root')
    return helper.files(base, entries)


def provenance(run, receipt, h):
    require, read, sha = h.require, h.read, h.sha
    require(sha(TESTS) == TESTS_SHA, 'Frozen launcher CPU receipt differs')
    tests = read(TESTS)
    require(tests['passed'] is True and tests['tests_run'] == 19 and tests['errors'] == tests['failures'] == 0,
            'Frozen fake-test status differs')
    require(sha(run / 'source-manifest.json') == receipt['source_manifest_sha256'], 'Source manifest differs')
    source = read(run / 'source-manifest.json')
    source_files = archive_files(h, run / 'source', source['files'])
    require(len(source_files) == receipt['source_file_count'] == 197, 'Frozen source count differs')
    dependencies = source['dependencies']
    require(dependencies['tracked_dependency_changes'] == ''
            and re.fullmatch('[0-9a-f]{40}', dependencies['repository_head']) is not None, 'Source dependency attestation differs')
    for line in dependencies['submodules'].splitlines():
        require(re.match(r'^\s*[0-9a-f]{40}\s+\S+', line) is not None, 'Submodule identity malformed')
    require(sha(run / 'bundle/bundle.json') == receipt['bundle_manifest_sha256'], 'Bundle manifest differs')
    bundle = archive_files(h, run / 'bundle', read(run / 'bundle/bundle.json')['files'])
    bundle_map = {entry['path']: entry['sha256'] for entry in bundle}
    require(bundle_map['cluster-inference'] == BINARY_SHA, 'Native binary differs')
    for name in ('rank_worker.py', 'artifacts.py'):
        require(bundle_map[name] == sha(run / 'source/experiments/cluster/runtime' / name), 'Bundle runtime differs from source snapshot')
    launcher = archive_files(h, run / 'launcher', receipt['launcher_files'])
    tested = {entry['path']: entry['sha256'] for entry in tests['source_files'] if entry['path'].endswith('.py')}
    require({entry['path']: entry['sha256'] for entry in launcher} == tested, 'Archived launcher differs from tested frozen draft')
    require(sha(run / 'controls/control-manifest.json') == receipt['control_manifest_sha256'], 'Control manifest differs')
    controls = archive_files(h, run / 'controls', read(run / 'controls/control-manifest.json')['files'])
    require({entry['path'] for entry in controls} == {'remote_prefill_control.py', 'prefill_compute_memory.py', 'artifacts.py', 'control-config.json'},
            'Pinned control inventory differs')
    for name in ('remote_prefill_control.py', 'prefill_compute_memory.py'):
        require(sha(run / 'controls' / name) == tested[name], 'Staged control source differs')
    require(sha(run / 'controls/artifacts.py') == bundle_map['artifacts.py'], 'Control artifact verifier differs')
    native = archive_files(h, run, receipt['native_files'])
    require({entry['path'] for entry in native} == {'native/rank.json', 'native/stdout.jsonl', 'native/stderr.log'}
            and (run / 'native/stderr.log').stat().st_size == 0, 'Native output inventory/stderr differs')
    inputs = archive_files(h, run, receipt['inputs']['files'])
    metadata = archive_files(h, run, receipt['retrieved_remote_metadata'])
    return dict(source=source_files, bundle=bundle, launcher=launcher, controls=controls,
                native=native, inputs=inputs, metadata=metadata, dependencies=dependencies), bundle_map


def workload_and_controls(run, receipt, bundle_map, h):
    require, read, sha = h.require, h.read, h.sha
    # These already hash-bound modules have no import-time reads or native calls.
    sys.path.insert(0, str(run / 'launcher'))
    contract = importlib.import_module('prefill_compute_contract')
    inputs = importlib.import_module('prefill_compute_inputs')
    require(receipt['artifact_aggregate_sha256'] == inputs.ARTIFACT
            and receipt['configuration_sha256'] == inputs.CONFIGURATION, 'Fixed artifact/configuration pin differs')
    prompt = receipt['inputs']['prompt']; remote = receipt['remote_paths']
    require(len(prompt) == 65 and all(type(x) is int and 0 <= x < inputs.VOCABULARY for x in prompt)
            and receipt['inputs']['teacher'] == [] and read(run / 'inputs/prompt.json') == prompt, 'Fixed request differs')
    require(sha(run / 'inputs/origin-receipt.json') == inputs.ORIGIN_RECEIPT
            and sha(run / 'inputs/expected-inventory.json') == inputs.EXPECTED_INVENTORY, 'Original input/inventory pins differ')
    origin = read(run / 'inputs/origin-receipt.json')
    require(prompt == read(run / 'inputs/origin-prompt-65.json') == read(run / 'inputs/origin-prompt-96.json')[:65]
            == origin['tokenization']['prompt_ids'][:65]
            and sha(run / 'inputs/source-text.txt') == origin['tokenization']['source_text_sha256'], 'Retained prose-token provenance differs')
    expected_rank = contract.configuration(Path(remote['bundle']), receipt['bundle_manifest_sha256'], Path(remote['model']), prompt, 180)
    require(read(run / 'native/rank.json') == read(run / 'remote-metadata/rank.final.json') == expected_rank
            and sha(run / 'native/rank.json') == receipt['rank_configuration_sha256'], 'Exact rank config differs')
    prompt_hash = hashlib.sha256(json.dumps(prompt).encode()).hexdigest()
    require(sha(run / 'remote-metadata/prompt.final.json') == prompt_hash, 'Remote token bytes differ')
    config = read(run / 'controls/control-config.json')
    require(config == dict(remote, run_id=receipt['run_id'], bundle_sha256=receipt['bundle_manifest_sha256'],
                binary_sha256=BINARY_SHA, rank_sha256=receipt['rank_configuration_sha256'], artifact_sha256=inputs.ARTIFACT,
                configuration_sha256=inputs.CONFIGURATION, prompt_sha256=prompt_hash), 'Pinned control configuration differs')
    for phase in ('before', 'after'):
        record = receipt['remote_' + phase]
        require(record['artifact_aggregate_sha256'] == inputs.ARTIFACT
                and record['bundle_manifest_sha256'] == receipt['bundle_manifest_sha256']
                and record['bundle_file_sha256'] == bundle_map
                and record['rank_configuration_sha256'] == receipt['rank_configuration_sha256'], 'Remote verification attestation differs')
        for name in ('config.json', 'manifest.json'):
            item = record['model_metadata'][name]
            local = run / 'remote-metadata' / (phase + '-' + name)
            require(item['sha256'] == sha(local) and item['size_bytes'] == local.stat().st_size
                    and item['remote_path'] == remote['run'] + '/metadata/' + phase + '-' + name,
                    'Copied remote metadata attestation differs')
    require(receipt['remote_after']['prompt_sha256'] == prompt_hash, 'Remote postflight input attestation differs')
    for name in ('config.json', 'manifest.json'):
        require(sha(run / 'remote-metadata' / ('before-' + name)) == sha(run / 'remote-metadata' / ('after-' + name)), 'Remote model metadata changed')
    require(sha(run / 'remote-metadata/before-config.json') == inputs.CONFIGURATION, 'Remote config differs from pin')
    manifest = read(run / 'remote-metadata/before-manifest.json')
    listed = {entry['path']: entry for entry in manifest['files']}
    aggregate = hashlib.sha256(b''.join(bytes.fromhex(listed[name]['sha256']) for name in sorted(listed))).hexdigest()
    require(len(listed) == len(manifest['files']) == manifest['file_count']
            and sum(entry['size_bytes'] for entry in listed.values()) == manifest['total_size_bytes'] == 6113952230
            and aggregate == manifest['aggregate_sha256'] == inputs.ARTIFACT, 'Retained manifest declaration differs')
    raw = (run / 'native/stdout.jsonl').read_bytes()
    require(len(raw) == 2669403 and sha(run / 'native/stdout.jsonl') == '10971a2556dbbfecf6557ba67375646a035483b4c3cbe937a67b7f22adfb8597', 'Pinned native stdout differs')
    lines = raw.splitlines(); require(len(lines) == 2 and raw.endswith(b'\n'), 'Expected two complete native records')
    rows = [contract.parse(line) for line in lines]
    contract.validate_first(rows[0], prompt); contract.validate_final(rows[1], rows[0])
    return dict(exactNativeConfigurationVerified=True, outerNativeRecordsVerified=2,
                numericalComparisonIndependentlyVerified=False, declaredArtifactPayloadBytes=manifest['total_size_bytes'],
                remoteFullArtifactBeforeAfterAttestationsMatch=True, modelPayloadIndependentlyRehashed=False,
                stdoutSHA256=sha(run / 'native/stdout.jsonl'))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('run', type=Path)
    parser.add_argument('--receipt-sha256', required=True)
    parser.add_argument('--postflight', type=Path, required=True)
    parser.add_argument('--postflight-sha256', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args(argv)
    h = pure_helpers(); require, sha, read = h.require, h.sha, h.read
    run = args.run.resolve(strict=True)
    require(not args.output.exists(), 'Preserve any earlier audit')
    require(args.receipt_sha256 == RECEIPT_SHA == sha(run / 'receipt.json')
            and args.postflight_sha256 == POSTFLIGHT_SHA == sha(args.postflight), 'Final receipt/postflight pin differs')
    receipt = read(run / 'receipt.json')
    require(receipt['kind'] == 'remote_qwen_layer_stage_prefill_launcher' and receipt['schema_version'] == 1
            and receipt['passed'] is True and receipt['native_execution_attempted'] is True
            and receipt['native_process_count'] == 1 and receipt['timeout_seconds'] == 180
            and receipt['source_bundle_inputs_and_remote_model_unchanged_after_run'] is True
            and receipt['physical_two_machine_execution'] is False and receipt['interprocess_model_transport'] is False
            and receipt['throughput_qualification'] is False and receipt['independent_comparison_oracle_run'] is False
            and receipt['local_model_payload_verified'] is False and receipt['remote_pid_observations_are_not_reaping_proof'] is True,
            'Launcher completion/scope differs')
    execution = receipt['execution']
    require(execution['passed'] is True and execution['exit_code'] == 0 and execution['local_ssh_client_reaped'] is True
            and execution['remote_process_reaping_independently_verified'] is False and execution['validated_outer_records'] == 2
            and execution['error'] is None and execution['cancellation_reason'] is None, 'Execution completion/scope differs')
    inventories, bundle = provenance(run, receipt, h)
    workload = workload_and_controls(run, receipt, bundle, h)
    observations = controls_sequence(run / 'remote-observations', receipt, read, sha)
    resources = validate_resources(receipt)
    require(len(observations) == 15 and resources['samples'] == 14, 'Saved observation count differs')
    postflight = read(args.postflight)
    require(postflight['kind'] == 'root_remote_prefill_postflight' and postflight['schemaVersion'] == 1
            and postflight['passed'] is True and postflight['launcherReceiptSHA256'] == RECEIPT_SHA
            and postflight['localSSHClientPID'] == execution['local_ssh_client_pid']
            and postflight['localSSHClientReaped'] is True and postflight['remoteReapingIndependentlyProven'] is False
            and postflight['remoteWorkerCleanupSourceBound'] is True and postflight['rootLauncherTerminalExitCode'] == 0
            and postflight['sshExitCode'] == 0 and postflight['sshStderr'] == ''
            and postflight['observation']['ownedLiveProcesses'] == []
            and postflight['observation']['remoteRun'] == receipt['remote_paths']['run'], 'Saved root postflight differs')
    utc(postflight['observation']['timestampUTC'])
    level, swap = memory_values(postflight['observation']['memory'])
    require(level <= 2 and swap == 0, 'Saved postflight pressure/swap differs')
    result = dict(kind='remote_prefill_provenance_audit', schemaVersion=1, status='passed', cpuOnly=True,
        auditedAtUTC=datetime.now(timezone.utc).isoformat(), auditScriptSHA256=sha(Path(__file__)),
        auditHelperSHA256=sha(ROOT / 'remote_prefill_provenance_records.py'), priorPureHelperSourceSHA256=PRIOR_SHA,
        launcherReceiptSHA256=RECEIPT_SHA, frozenLauncherTestReceiptSHA256=TESTS_SHA, launcherFakeTests=19,
        rootPostflightSHA256=POSTFLIGHT_SHA, nativeBinarySHA256=BINARY_SHA,
        sourceManifestSHA256=receipt['source_manifest_sha256'], bundleManifestSHA256=receipt['bundle_manifest_sha256'],
        controlManifestSHA256=receipt['control_manifest_sha256'], inventoriesVerified=inventories,
        savedControlSequence=observations, workload=workload, resources=resources,
        localSSHClientPID=execution['local_ssh_client_pid'], localSSHClientReaped=True,
        savedRootPostflightReportsNoOwnedProcesses=True, remoteReapingIndependentlyProven=False,
        remotePythonVersion=postflight['observation']['pythonVersion'], currentProcessInventoryPerformed=False,
        nativeExecutions=0, SSHExecutions=0, modelPayloadBytesRead=0,
        limitations=['Model/bundle remote verification is bound to pinned root-run controls and their saved results; this audit does not rehash remote model payloads or reproduce a build.',
            'Native comparison, retirement, and weak model release remain source-bound declarations; the numerical oracle is a separate audit.',
            'RSS values are sampled integers from the pinned ps parser. Raw ps text was not persisted, so their original numeric conversion cannot be independently replayed; no process peak is inferred.',
            'Control-call file sequence is checked. Monotonic values from separate remote Python processes are not assumed comparable.',
            'The frozen launcher can overwrite a primary failure reason if cleanup also fails. This successful run had neither error; no frozen source is rewritten.',
            'The same single-process native check ran on a different execution host. No distributed transport, hardware speedup, or throughput qualification is asserted.'])
    require(sha(run / 'receipt.json') == RECEIPT_SHA and sha(args.postflight) == POSTFLIGHT_SHA
            and sha(TESTS) == TESTS_SHA and sha(PRIOR) == PRIOR_SHA, 'Pinned metadata changed during audit')
    with args.output.open('x') as stream:
        json.dump(result, stream, indent=2, sort_keys=True, allow_nan=False); stream.write('\n')
    print(json.dumps(dict(status='passed', output=str(args.output), sha256=sha(args.output),
        sourceFiles=len(inventories['source']), controlRecords=len(observations), memorySamples=resources['samples']), sort_keys=True))


if __name__ == '__main__':
    main()
