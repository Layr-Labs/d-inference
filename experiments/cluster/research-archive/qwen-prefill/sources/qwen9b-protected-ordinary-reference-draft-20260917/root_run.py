"""Explicit root-only ordinary-reference launch/collection, never member routing."""
import argparse
import hashlib
import json
from pathlib import Path
import shlex
import sys

BASE = Path(__file__).resolve().parent
sys.path.insert(0, str(BASE / 'package'))
from binding_common import parse, require, same
from binding_inputs import snapshot
from reference_inputs import write_json, validate_job
from reference_settings import REMOTE, require_short
from parent_settings import SSH
from local_process import execute
from receive_collection import receive
from validate_collected import validate
from verify_sources import verify


def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('action', choices=['run', 'collect'])
    parser.add_argument('--inputs', required=True, type=Path)
    parser.add_argument('--binding-sha256', required=True)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--launch-receipt', type=Path)
    parser.add_argument('--launch-receipt-sha256')
    parser.add_argument('--failed-run', action='store_true')
    args = parser.parse_args()
    verify()
    trust = parse((BASE / 'trust.json').read_bytes())
    same(snapshot(Path(trust['path']), 65536)['sha256'], trust['sha256'], 'Strict SSH known-hosts pin')
    actual = snapshot(args.inputs / 'binding.json', 16384); same(actual['sha256'], args.binding_sha256, 'Actual input binding pin')
    binding = parse(actual['raw'])
    job_raw = snapshot(args.inputs / 'job.json', 16384); same(job_raw['sha256'], binding['jobSHA256'], 'Actual job pin')
    job = validate_job(parse(job_raw['raw'])); require_short(job)
    same(snapshot(BASE / 'package/manifest.json', 1024**2)['sha256'], binding['launcherSHA256'], 'Frozen launcher pin')
    require(args.output.is_absolute() and args.output.parent.resolve() == args.output.parent, 'Canonical fresh output')
    args.output.mkdir(mode=0o700)
    if args.action == 'run':
        require(not args.failed_run, 'Failure collection flag is not a run mode')
        command = shlex.join(['/usr/bin/python3', '-B', str(REMOTE / 'package/launch_reference.py'),
            '--job', str(REMOTE / 'inputs/job.json'), '--job-sha256', binding['jobSHA256'],
            '--launcher-sha256', binding['launcherSHA256']])
        code = execute(SSH + ['darkbloom-48', command], args.output, 'launch', 360, cap=1024**2)
        require(code == 0, 'Reference launch failed; collect its retained evidence separately')
        require((args.output / 'launch.stderr').stat().st_size == 0, 'SSH launch emitted stderr')
        raw = snapshot(args.output / 'launch.stdout', 16384)['raw']; result = parse(raw)
        same(result['schema'], 'qwen9b_reference_launch_terminal_v1', 'Remote launch receipt schema')
        for key, value in dict(jobSHA256=binding['jobSHA256'], launcherSHA256=binding['launcherSHA256'],
                               runDirectory=str(REMOTE / 'runs/reference-1'), status='completed', exitCode=0).items():
            same(result.get(key), value, 'Launch receipt ' + key)
        result['bindingSHA256'] = args.binding_sha256
        result['rootLaunchExecutionSHA256'] = snapshot(args.output / 'launch.execution.json', 16384)['sha256']
        write_json(args.output / 'launch-receipt.json', result)
        print(json.dumps(dict(receipt=str(args.output / 'launch-receipt.json'),
                              sha256=snapshot(args.output / 'launch-receipt.json', 16384)['sha256'])))
    else:
        launch = None
        if args.failed_run:
            require(args.launch_receipt is None and args.launch_receipt_sha256 is None, 'Raw failure collection cannot assert successful launch binding')
        else:
            require(args.launch_receipt is not None and args.launch_receipt_sha256 is not None, 'Original successful root launch pin required')
            item = snapshot(args.launch_receipt, 16384); same(item['sha256'], args.launch_receipt_sha256, 'Original root launch receipt')
            launch = parse(item['raw']); same(launch['bindingSHA256'], args.binding_sha256, 'Run/collection input join')
            same(launch['jobSHA256'], binding['jobSHA256'], 'Run/collection job join')
        command = shlex.join(['/usr/bin/python3', '-B', str(REMOTE / 'package/remote_evidence.py'),
                              'collect', '--mode', 'reference', '--attempt', '1'])
        code = execute(SSH + ['darkbloom-48', command], args.output, 'archive', 60, cap=65*1024**2)
        require(code == 0 and (args.output / 'archive.stderr').stat().st_size == 0, 'Reference collection failed')
        directory = args.output / 'returned'
        header = receive(args.output / 'archive.stdout', directory)
        result = (dict(rawFailureEvidenceCollected=True, referenceQualified=False)
                  if args.failed_run else validate(directory, header, launch, binding, job))
        write_json(args.output / ('failure-collection.json' if args.failed_run else 'reference-result.json'), result)
        print(json.dumps(result, sort_keys=True))
    verify()


if __name__ == '__main__':
    main()
