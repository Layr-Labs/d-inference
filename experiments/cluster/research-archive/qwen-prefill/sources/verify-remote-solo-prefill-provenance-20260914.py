#!/usr/bin/env python3
"""CPU-only provenance audit; native output numerics and timing remain opaque."""
import argparse
from datetime import datetime, timezone
from decimal import Decimal
from pathlib import Path
import json
import sys
sys.dont_write_bytecode = True
from solo_prefill_provenance_archive import (LAUNCHER_REVIEW, LAUNCHER_REVIEW_SHA, PRIOR_SHA,
    RESOURCE_HELPER_SHA, ROOT, archive_files, provenance, pure_helpers, workload_and_controls)
from solo_prefill_provenance_records import BINARY, valid_hash, validate_completion
from remote_prefill_provenance_records import controls_sequence, memory_values, utc, validate_resources


def validate_postflight(postflight, receipt, receipt_sha, resources, h):
    script = ROOT / 'postflight-remote-solo-prefill-20260914.py'
    helper = ROOT / 'solo_prefill_provenance_records.py'
    execution = receipt['execution']
    h.require(postflight['kind'] == 'root_remote_solo_prefill_postflight'
        and type(postflight['schemaVersion']) is int and postflight['schemaVersion'] == 1
        and postflight['passed'] is True and postflight['launcherReceiptSHA256'] == receipt_sha
        and postflight['scriptSHA256'] == h.sha(script) and postflight['helperSHA256'] == h.sha(helper)
        and postflight['runID'] == receipt['run_id'] and postflight['nativeBinarySHA256'] == BINARY
        and postflight['localSSHClientPID'] == execution['local_ssh_client_pid']
        and postflight['localSSHClientReaped'] is True and postflight['remoteReapingIndependentlyProven'] is False
        and postflight['remoteWorkerCleanupSourceBound'] is True and postflight['rootLauncherTerminalExitCode'] == 0
        and postflight['sshExitCode'] == 0 and postflight['sshStderr'] == '' and 'error' not in postflight
        and postflight['observation']['ownedLiveProcesses'] == []
        and postflight['observation']['remoteRun'] == receipt['remote_paths']['run'], 'Saved root postflight differs')
    for name in ('rank_worker.py', 'processes.py'):
        h.require(postflight['cleanupSourceSHA256'][name]
            == h.sha(Path(receipt['_audit_run']) / 'source/experiments/cluster/runtime' / name), 'Cleanup source pin differs')
    utc(postflight['observation']['timestampUTC'])
    level, swap = memory_values(postflight['observation']['memory'])
    h.require(level <= 2 and swap <= Decimal(resources['reportedSwapBaselineBytes']), 'Postflight pressure/swap increased')
    return dict(scriptSHA256=h.sha(script), helperSHA256=h.sha(helper), pressureLevel=level,
                reportedSwapBytes=str(swap), remotePythonVersion=postflight['observation']['pythonVersion'])


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('run', type=Path)
    parser.add_argument('--receipt-sha256', required=True)
    parser.add_argument('--postflight', type=Path, required=True)
    parser.add_argument('--postflight-sha256', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args(argv)
    valid_hash(args.receipt_sha256); valid_hash(args.postflight_sha256)
    h = pure_helpers(); run = args.run.resolve(strict=True)
    sources = {name: h.sha(ROOT / name) for name in ('verify-remote-solo-prefill-provenance-20260914.py',
        'solo_prefill_provenance_archive.py', 'solo_prefill_provenance_records.py',
        'postflight-remote-solo-prefill-20260914.py')}
    h.require(not args.output.exists(), 'Preserve any earlier audit')
    pins = {run / 'receipt.json': args.receipt_sha256, args.postflight: args.postflight_sha256,
            LAUNCHER_REVIEW: LAUNCHER_REVIEW_SHA}
    for path, pin in pins.items(): h.require(h.sha(path) == pin, 'Pinned input differs: ' + str(path))
    receipt, tests = h.read(run / 'receipt.json'), h.read(LAUNCHER_REVIEW)
    execution = validate_completion(receipt)
    inventories, bundle = provenance(run, receipt, tests, h)
    frozen_review_files = archive_files(h, LAUNCHER_REVIEW.parent, tests['files'])
    workload = workload_and_controls(run, receipt, bundle, h)
    observations = controls_sequence(run / 'remote-observations', receipt, h.read, h.sha)
    resources = validate_resources(receipt)
    postflight = h.read(args.postflight)
    postflight_details = validate_postflight(postflight, dict(receipt, _audit_run=str(run)), args.receipt_sha256, resources, h)
    result = dict(kind='remote_solo_prefill_provenance_audit', schemaVersion=1, status='passed', cpuOnly=True,
        auditedAtUTC=datetime.now(timezone.utc).isoformat(), auditSourceSHA256=sources,
        resourceHelperSHA256=RESOURCE_HELPER_SHA, priorPureHelperSourceSHA256=PRIOR_SHA,
        launcherReceiptSHA256=args.receipt_sha256, frozenLauncherReviewSHA256=LAUNCHER_REVIEW_SHA,
        frozenLauncherFakeTests=36, frozenReviewFiles=frozen_review_files,
        rootPostflightSHA256=args.postflight_sha256, nativeBinarySHA256=BINARY,
        sourceManifestSHA256=receipt['source_manifest_sha256'], bundleManifestSHA256=receipt['bundle_manifest_sha256'],
        controlManifestSHA256=receipt['control_manifest_sha256'], inventoriesVerified=inventories,
        savedControlSequence=observations, workload=workload, resources=resources, postflight=postflight_details,
        localSSHClientPID=execution['local_ssh_client_pid'], localSSHClientReaped=True,
        savedRootPostflightReportsNoOwnedProcesses=True, remoteReapingIndependentlyProven=False,
        currentProcessInventoryPerformed=False, nativeExecutions=0, SSHExecutions=0, modelPayloadBytesRead=0,
        limitations=['Remote model/bundle identity is bound to pinned controls and saved before/after results; no remote payload rehash or build reproduction is performed.',
            'Native stdout is checked only as two bounded opaque records and by its saved hash. No numerical, reference-quality, timing, release, or throughput claim is independently inferred from it.',
            'RSS observations are sampled KiB-derived integers; original ps text was not archived, and no peak or zero-for-missing claim is made.',
            'Saved control-call order is checked; monotonic epochs from separate remote Python processes are not assumed shared.',
            'Root postflight observes the exact owned paths absent; this is not remote waitpid/reaping proof.',
            'The admitted descriptor is a pinned reference assertion. Verifying its two byte encodings does not establish baseline evidence derivation or model quality.'])
    for path, pin in pins.items(): h.require(h.sha(path) == pin, 'Pinned input changed during audit')
    for name, pin in sources.items(): h.require(h.sha(ROOT / name) == pin, 'Audit source changed during audit')
    with args.output.open('x') as stream:
        json.dump(result, stream, indent=2, sort_keys=True, allow_nan=False); stream.write('\n')
    print(json.dumps(dict(status='passed', output=str(args.output), sha256=h.sha(args.output),
        sourceFiles=len(inventories['source']), controlRecords=len(observations), memorySamples=resources['samples']), sort_keys=True))


if __name__ == '__main__':
    main()
