#!/usr/bin/env python3
"""Root-only read-only postflight; frozen run archive, never live source tree."""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import shlex
import subprocess
import sys
from long_reference_postflight_payload import REMOTE
from long_reference_provenance_common import Pins, files, read, require, sha, valid_hash
from long_reference_provenance_records import validate_completion, validate_layout


def cleanup_source_identity(run, receipt, native):
    require(sha(run / 'source-manifest.json') == receipt['source_manifest_sha256']
            and sha(run / 'bundle/bundle.json') == receipt['bundle_manifest_sha256'], 'Cleanup manifests differ')
    source = {entry['path']: entry for entry in read(run / 'source-manifest.json')['files']}
    bundle = {entry['path']: entry for entry in read(run / 'bundle/bundle.json')['files']}
    require(bundle['cluster-inference']['sha256'] == native, 'Explicit native pin differs')
    selected = [source['experiments/cluster/runtime/' + name] for name in ('rank_worker.py', 'processes.py')]
    sources = files(run / 'source', selected)
    files(run / 'bundle', [bundle['rank_worker.py'], bundle['cluster-inference']])
    require(bundle['rank_worker.py']['sha256'] == sources['experiments/cluster/runtime/rank_worker.py'],
            'Staged worker cleanup source differs')
    require(sha(run / 'native/rank.json') == receipt['rank_configuration_sha256'], 'Owned rank config changed')
    rank = read(run / 'native/rank.json')
    require(rank['bundle'] == receipt['remote_paths']['bundle'] and type(rank['rank']) is int
            and rank['rank'] == 0 and rank['persistent'] is False, 'Owned worker configuration differs')
    return {name: sources['experiments/cluster/runtime/' + name] for name in ('rank_worker.py', 'processes.py')}


def observe(receipt, invoke):
    validate_layout(receipt)
    command = ['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5', receipt['execution_host'],
        shlex.join(['/usr/bin/python3', '-c', REMOTE, json.dumps(receipt['remote_paths'], allow_nan=False)])]
    result = invoke(command, capture_output=True, text=True, timeout=20)
    require(len(result.stdout.encode()) <= 2 * 1024**2 and len(result.stderr.encode()) <= 65536,
            'SSH output exceeded bound')
    from long_reference_provenance_common import parse
    observation = parse(result.stdout) if result.returncode == 0 else None
    if observation is not None:
        require(observation['remoteRun'] == receipt['remote_paths']['run']
                and type(observation['ownedLiveProcesses']) is list, 'Postflight run identity differs')
    return dict(sshExitCode=result.returncode, sshStderr=result.stderr, observation=observation,
                passed=result.returncode == 0 and not result.stderr and observation['ownedLiveProcesses'] == [])


def main(argv=None, invoke=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('run', type=Path)
    parser.add_argument('--receipt-sha256', required=True)
    parser.add_argument('--expected-native-sha256', required=True)
    parser.add_argument('--root-launcher-exit-code', type=int, choices=[0], required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args(argv)
    valid_hash(args.receipt_sha256); valid_hash(args.expected_native_sha256)
    run = args.run.resolve(strict=True)
    require(not args.output.exists(), 'Preserve earlier postflight')
    source = run / 'receipt.json'; require(sha(source) == args.receipt_sha256, 'Launcher receipt pin differs')
    receipt = read(source)
    # Only receipt/native pins are independent postflight inputs. Model/prompt
    # claims remain the separate provenance/numerical auditor's responsibility.
    pins = Pins(args.expected_native_sha256, receipt['artifact_aggregate_sha256'], receipt['configuration_sha256'],
                receipt['inputs']['prompt_file_sha256'], receipt['inputs']['prompt_origin_file_sha256'])
    execution = validate_completion(receipt, pins)
    cleanup = cleanup_source_identity(run, receipt, pins.native)
    folder = Path(__file__).parent
    names = ['postflight_remote_long_pair.py', 'long_reference_postflight_payload.py',
             'long_reference_provenance_common.py', 'long_reference_provenance_records.py']
    hashes = {name: sha(folder / name) for name in names}
    record = dict(kind='root_remote_long_pair_postflight', schemaVersion=1,
        timestampUTC=datetime.now(timezone.utc).isoformat(), launcherReceiptSHA256=args.receipt_sha256,
        sourceSHA256=hashes, runID=receipt['run_id'], nativeBinarySHA256=pins.native,
        cleanupSourceSHA256=cleanup, rootLauncherTerminalExitCode=0,
        remoteReapingIndependentlyProven=False, remoteWorkerCleanupSourceBound=True,
        liveRepositoryCompared=False, localSSHClientPID=execution['local_ssh_client_pid'],
        localSSHClientReaped=True, observation=None, passed=False)
    try: record.update(observe(receipt, invoke or subprocess.run))
    except Exception as error: record['error'] = type(error).__name__ + ': ' + str(error)
    require(sha(source) == args.receipt_sha256 and all(sha(folder / name) == pin for name, pin in hashes.items()),
            'Receipt/postflight source changed while observing')
    with args.output.open('x') as stream:
        json.dump(record, stream, indent=2, sort_keys=True, allow_nan=False); stream.write('\n')
    print(json.dumps(dict(passed=record['passed'], output=str(args.output), sha256=sha(args.output))))
    return 0 if record['passed'] else 1


if __name__ == '__main__': sys.exit(main())
