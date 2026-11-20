#!/usr/bin/env python3
"""Audit one pinned serial/lookahead two-rank run without parsing native results."""
import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import sys
sys.dont_write_bytecode = True
from rank_prefill_provenance_audit import archives, workload, resources_and_controls

ROOT = Path(__file__).resolve().parent
PREVIOUS = ROOT / 'verify-remote-prefill-provenance-20260914.py'
PREVIOUS_SHA = '3dbf7e2a3090f47290a509f4b5f8d49a1715d47eb46b23e141bf8e233e1f32bd'
SHARED = ROOT / 'remote_prefill_provenance_records.py'
SHARED_SHA = '7c1b2119eedb067fe56a8290f4a63ac04efb474c5cf6981b30f04767deccc1a8'
TESTS = ROOT / 'remote-prefill-rank-launcher-draft/draft-cpu-check-receipt.json'
TESTS_SHA = '27cf9cd78a9aec59461ccec638ea35c75cc478c43e1f269afcfaf9ad6323e333'
BINARY_SHA = '9341ca3b3dc5190ffa6759cfd045300a29422a0094710c13b88dcc39afe8ca16'


def module(path, name, expected):
    if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
        raise ValueError('Pinned pure helper differs: ' + str(path))
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec); spec.loader.exec_module(result)
    return result


def postflight(path, expected, receipt_pin, receipt, h, shared):
    h.require(h.sha(path) == expected, 'Postflight pin differs')
    value = h.read(path); cohort = receipt['cohort']
    h.require(value['kind'] == 'root_remote_prefill_rank_postflight' and value['schemaVersion'] == 1
        and value['passed'] is True and value['launcherReceiptSHA256'] == receipt_pin
        and value['epoch'] == receipt['epoch'] and value['policy'] == receipt['stage_prefill_policy']
        and value['localSSHClientPIDs'] == cohort['local_ssh_client_pids']
        and value['localSSHClientsReaped'] == [True, True]
        and value['remoteReapingIndependentlyProven'] is False and value['remoteWorkerCleanupSourceBound'] is True
        and value['rootLauncherTerminalExitCode'] == 0 and value['sshExitCode'] == 0 and value['sshStderr'] == ''
        and value['observation']['ownedLiveProcesses'] == []
        and value['observation']['remoteRun'] == receipt['remote_paths']['run'], 'Root postflight scope/identity differs')
    reader = ROOT / 'postflight-remote-prefill-ranks-20260914.py'
    h.require(h.sha(reader) == value['scriptSHA256'], 'Root postflight reader source differs')
    shared.utc(value['observation']['timestampUTC'])
    level, swap = shared.memory_values(value['observation']['memory'])
    h.require(level <= 2 and swap == 0, 'Root postflight pressure/swap differs')
    return dict(path=str(path), sha256=expected, readerScriptSHA256=value['scriptSHA256'],
        savedInventoryReportsNoOwnedProcesses=True, independentRemoteReapingProven=False,
        currentProcessInventoryPerformed=False, pythonVersion=value['observation']['pythonVersion'])


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('run', type=Path)
    parser.add_argument('--policy', choices=['serial_v1', 'prompt_lookahead_one_v1'], required=True)
    parser.add_argument('--receipt-sha256', required=True)
    parser.add_argument('--postflight', type=Path, required=True)
    parser.add_argument('--postflight-sha256', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args(argv)
    old = module(PREVIOUS, 'frozen_single_prefill_audit', PREVIOUS_SHA)
    shared = module(SHARED, 'frozen_prefill_resource_helpers', SHARED_SHA)
    h = old.pure_helpers(); require, sha, read = h.require, h.sha, h.read
    require(not args.output.exists(), 'Preserve existing audit output')
    require(all(re.fullmatch('[0-9a-f]{64}', pin) is not None for pin in [args.receipt_sha256, args.postflight_sha256]), 'Explicit final pins required')
    run = args.run.resolve(strict=True)
    require(sha(run / 'receipt.json') == args.receipt_sha256 and sha(TESTS) == TESTS_SHA, 'Final launch/test receipt pin differs')
    tests = read(TESTS)
    require(tests['passed'] is True and tests['tests_run'] == 22 and tests['errors'] == tests['failures'] == 0, 'Frozen test completion differs')
    receipt = read(run / 'receipt.json')
    require(receipt['kind'] == 'remote_qwen_layer_stage_prefill_rank_launcher' and receipt['schema_version'] == 1
        and receipt['passed'] is True and receipt['native_execution_attempted'] is True and receipt['native_rank_count'] == 2
        and receipt['transport'] == 'loopback-test' and receipt['backend'] == 'ring'
        and receipt['flow'] == 'bounded_prefill_measurement_v1' and receipt['envelope_version'] == 3
        and receipt['stage_prefill_policy'] == args.policy and receipt['stage_logits_dtype'] == 'bfloat16'
        and receipt['physical_two_machine_execution'] is False and receipt['throughput_qualification'] is False
        and receipt['independent_execution_oracle_run'] is False and receipt['timeout_seconds'] == 180
        and receipt['model_payload_copies_created'] is False and receipt['local_model_payload_verified'] is False
        and receipt['source_bundle_inputs_and_remote_model_unchanged_after_run'] is True
        and receipt['remote_pid_observations_are_not_reaping_proof'] is True and receipt['final_cleanup_errors'] == [],
        'Launcher completion/scope differs')
    cohort = receipt['cohort']
    require(cohort['passed'] is True and cohort['exit_codes'] == [0, 0] and cohort['local_ssh_clients_reaped'] == [True, True]
        and cohort['remote_process_reaping_independently_verified'] is False
        and cohort['cancellation_reason'] is None and cohort['error'] is None and cohort['cleanup_errors'] == []
        and len(cohort['local_ssh_client_pids']) == len(set(cohort['local_ssh_client_pids'])) == 2
        and all(type(pid) is int and pid > 0 for pid in cohort['local_ssh_client_pids'])
        and cohort['validation'] == dict(records_per_rank=[2, 2], shared_agreement_matches=True, nested_execution_oracle_run=False),
        'Cohort completion/source-bound outer admission differs')
    inventories, bundle = archives(run, receipt, tests, BINARY_SHA, old, h)
    request = workload(run, receipt, BINARY_SHA, bundle, h)
    resources, observations = resources_and_controls(run, receipt, shared, h)
    saved_postflight = postflight(args.postflight, args.postflight_sha256, args.receipt_sha256, receipt, h, shared)
    result = dict(kind='remote_prefill_rank_provenance_audit', schemaVersion=1, status='passed', cpuOnly=True,
        auditedAtUTC=datetime.now(timezone.utc).isoformat(), auditScriptSHA256=sha(Path(__file__)),
        auditHelperSHA256=sha(ROOT / 'rank_prefill_provenance_audit.py'), previousPureAuditSHA256=PREVIOUS_SHA,
        sharedResourceHelperSHA256=SHARED_SHA, historicalReadHelperSHA256=old.PRIOR_SHA,
        launcherReceiptSHA256=args.receipt_sha256, frozenLauncherTestReceiptSHA256=TESTS_SHA, launcherFakeTests=22,
        nativeBinarySHA256=BINARY_SHA, policy=args.policy, epoch=receipt['epoch'],
        sourceManifestSHA256=receipt['source_manifest_sha256'], bundleManifestSHA256=receipt['bundle_manifest_sha256'],
        controlManifestSHA256=receipt['control_manifest_sha256'], inventoriesVerified=inventories,
        workload=request, resources=resources, savedControlSequence=observations, savedRootPostflight=saved_postflight,
        localSSHClientPIDs=cohort['local_ssh_client_pids'], localSSHClientsReaped=True,
        remoteReapingIndependentlyProven=False, sourceBoundLauncherOuterAdmission=cohort['validation'],
        nativeOutputNumericsParsed=False, nativeWireActionTimingOracleRun=False, nativeExecutions=0, SSHExecutions=0, modelPayloadBytesRead=0,
        limitations=['This audit hashes native output streams without parsing their numerical, wire, action, or timing records. The independent execution oracle is separate.',
            'Remote model and bundle verification is bound to pinned controls and saved root execution receipts; this audit does not reread remote payloads or reproduce a build.',
            'Per-rank RSS and simultaneous native-only sums are sampled observations, not peaks. Missing observations are never treated as zero; raw ps text was not persisted.',
            'Remote control-call file order is checked, but monotonic timestamps from separate Python processes are not assumed comparable.',
            'Local SSH reaping and a saved empty remote process inventory do not independently prove remote reaping.',
            'This is one remote machine running two loopback ranks with one bounded request; no two-machine transfer or throughput qualification is asserted.'])
    require(sha(run / 'receipt.json') == args.receipt_sha256 and sha(args.postflight) == args.postflight_sha256
        and sha(TESTS) == TESTS_SHA and sha(PREVIOUS) == PREVIOUS_SHA and sha(SHARED) == SHARED_SHA, 'Pinned metadata changed during audit')
    with args.output.open('x') as stream:
        json.dump(result, stream, indent=2, sort_keys=True, allow_nan=False); stream.write('\n')
    print(json.dumps(dict(status='passed', output=str(args.output), sha256=sha(args.output), policy=args.policy,
        sourceFiles=len(inventories['source']), memorySamples=resources['samples'],
        simultaneousNativeRSSSamples=resources['simultaneousNativeSampleCount']), sort_keys=True))


if __name__ == '__main__': main()
