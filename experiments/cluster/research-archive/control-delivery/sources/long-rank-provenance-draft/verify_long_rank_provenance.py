#!/usr/bin/env python3
"""CPU-only replay of frozen v4 rank archives; native output remains opaque."""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
from long_reference_provenance_common import Pins, read, require, sha, valid_hash
from long_rank_provenance_archive import provenance
from long_rank_provenance_records import POLICIES, validate_completion
from long_rank_provenance_resources import resources_and_controls
from long_rank_provenance_workload import workload_and_controls
from remote_prefill_provenance_records import memory_values, utc

RESOURCE_HELPER_SHA256 = '7c1b2119eedb067fe56a8290f4a63ac04efb474c5cf6981b30f04767deccc1a8'


def validate_postflight(record, receipt, receipt_sha, pins, policy, run):
    folder = Path(__file__).parent
    names = ['postflight_remote_long_ranks.py', 'long_rank_postflight_payload.py',
             'long_reference_provenance_common.py', 'long_rank_provenance_records.py']
    require(record['kind'] == 'root_remote_long_rank_postflight' and type(record['schemaVersion']) is int
            and record['schemaVersion'] == 1 and record['passed'] is True
            and record['launcherReceiptSHA256'] == receipt_sha
            and record['sourceSHA256'] == {name: sha(folder / name) for name in names}
            and record['epoch'] == receipt['epoch'] and record['policy'] == policy
            and record['nativeBinarySHA256'] == pins.native
            and record['localSSHClientPIDs'] == receipt['cohort']['local_ssh_client_pids']
            and all(type(x) is int for x in record['localSSHClientPIDs'])
            and record['localSSHClientsReaped'] == [True, True] and all(x is True for x in record['localSSHClientsReaped'])
            and record['remoteReapingIndependentlyProven'] is False and record['remoteWorkerCleanupSourceBound'] is True
            and record['liveRepositoryCompared'] is False
            and type(record['rootLauncherTerminalExitCode']) is int and record['rootLauncherTerminalExitCode'] == 0
            and type(record['sshExitCode']) is int and record['sshExitCode'] == 0
            and record['sshStderr'] == '' and 'error' not in record
            and record['observation']['ownedLiveProcesses'] == []
            and record['observation']['remoteRun'] == receipt['remote_paths']['run'], 'Saved postflight differs')
    for name in ('rank_worker.py', 'processes.py'):
        require(record['cleanupSourceSHA256'][name] == sha(run / 'source/experiments/cluster/runtime' / name),
                'Postflight cleanup source pin differs')
    utc(record['observation']['timestampUTC'])
    level, swap = memory_values(record['observation']['memory'])
    require(level <= 2 and swap == 0, 'Postflight pressure/swap gate failed')
    return dict(pressureLevel=level, reportedSwapBytes=str(swap), ownedProcessesObserved=0,
                remoteReapingIndependentlyProven=False)


def validate(run, receipt_sha, pins, policy, review_path, review_sha, origin_directory, postflight_path, postflight_sha):
    folder = Path(__file__).parent
    require(sha(folder / 'remote_prefill_provenance_records.py') == RESOURCE_HELPER_SHA256,
            'Frozen reused resource helper changed')
    required = {run / 'receipt.json': receipt_sha, review_path: review_sha, postflight_path: postflight_sha}
    for path, pin in required.items(): valid_hash(pin); require(sha(path) == pin, 'Explicit metadata pin differs')
    receipt = read(run / 'receipt.json'); cohort = validate_completion(receipt, pins, policy)
    inventories, bundle = provenance(run, receipt, pins, review_path, review_sha)
    workload = workload_and_controls(run, receipt, pins, bundle, origin_directory)
    resources, observations = resources_and_controls(run, receipt, read, sha)
    postflight = validate_postflight(read(postflight_path), receipt, receipt_sha, pins, policy, run)
    for path, pin in required.items(): require(sha(path) == pin, 'Pinned metadata changed during audit')
    return dict(kind='remote_long_rank_provenance_audit', schemaVersion=1, status='passed', cpuOnly=True,
        launcherReceiptSHA256=receipt_sha, frozenLauncherReviewSHA256=review_sha, rootPostflightSHA256=postflight_sha,
        nativeBinarySHA256=pins.native, epoch=receipt['epoch'], policy=policy,
        sourceManifestSHA256=receipt['source_manifest_sha256'], bundleManifestSHA256=receipt['bundle_manifest_sha256'],
        controlManifestSHA256=receipt['control_manifest_sha256'], inventoriesVerified=inventories,
        workload=workload, savedControlSequence=observations, resources=resources, postflight=postflight,
        localSSHClientPIDs=cohort['local_ssh_client_pids'], localSSHClientsReaped=True,
        remoteReapingIndependentlyProven=False, liveRepositoryCompared=False,
        nativeOutputNumericsParsed=False, nativeWireActionTimingOracleRun=False,
        nativeExecutions=0, SSHExecutions=0, modelPayloadBytesRead=0,
        limitations=['Each native stream is two bounded opaque lines. Numerical, wire, action and timing validation belong to the separate oracle.',
            'Saved full-artifact checks are pinned control attestations; this verifier neither rereads remote payloads nor reproduces a build.',
            'Raw prompt/origin hashes are reproduced, but tokenization is not rerun.',
            'Per-rank and simultaneous native RSS values are sparse observations, not peaks; missing observations are not zero.',
            'Local SSH reaping and saved empty remote inventories do not independently prove remote waitpid/reaping.',
            'Only frozen run archives are inspected; later authorized live-tree builds do not enter this audit.',
            'This is one host with two loopback ranks; no physical two-machine or throughput qualification is asserted.'])


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('run', type=Path)
    parser.add_argument('--policy', choices=POLICIES, required=True)
    for flag in ('receipt-sha256', 'expected-native-sha256', 'artifact-aggregate-sha256', 'configuration-sha256',
                 'long-prompt-sha256', 'prompt-origin-sha256', 'launcher-review-sha256', 'postflight-sha256'):
        parser.add_argument('--' + flag, required=True)
    for flag in ('launcher-review', 'origin-directory', 'postflight', 'output'):
        parser.add_argument('--' + flag, type=Path, required=True)
    args = parser.parse_args(argv)
    require(not args.output.exists(), 'Preserve earlier audit')
    pins = Pins(args.expected_native_sha256, args.artifact_aggregate_sha256, args.configuration_sha256,
                args.long_prompt_sha256, args.prompt_origin_sha256)
    result = validate(args.run.resolve(strict=True), args.receipt_sha256, pins, args.policy,
        args.launcher_review.resolve(strict=True), args.launcher_review_sha256, args.origin_directory,
        args.postflight.resolve(strict=True), args.postflight_sha256)
    result['auditedAtUTC'] = datetime.now(timezone.utc).isoformat()
    result['auditSourceSHA256'] = {p.name: sha(p) for p in sorted(Path(__file__).parent.glob('*.py'))}
    with args.output.open('x') as stream:
        json.dump(result, stream, indent=2, sort_keys=True, allow_nan=False); stream.write('\n')
    print(json.dumps(dict(status='passed', output=str(args.output), sha256=sha(args.output))))


if __name__ == '__main__': main()
