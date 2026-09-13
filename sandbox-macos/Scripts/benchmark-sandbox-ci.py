#!/usr/bin/env python3
"""Measure actual paired Go compilation/unit tests using identical offline inputs.

Requires an explicit local SDK and module cache, an immutable source revision,
and (unless --host-only) an explicitly confirmed nonproduction sandbox on this
same physical machine. Does not create/delete/renew sandboxes or change services.
"""
import argparse
import datetime as dt
import json
from pathlib import Path
import platform
import subprocess
import time
import uuid

from sandbox_ci_bundle import command, digest, prepare_bundle, write_json, validate_output_location
from sandbox_ci_evidence import summarize, validate_sample, verify_evidence_archive
from sandbox_ci_remote import Remote, validate_nonproduction_url


def main(arguments=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--repo', type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument('--revision', default='HEAD', help='commit/ref resolved once; dirty/untracked source is excluded')
    parser.add_argument('--go-sdk', type=Path, required=True)
    parser.add_argument('--module-cache', type=Path, required=True)
    parser.add_argument('--host-only', action='store_true')
    parser.add_argument('--cli', type=Path)
    parser.add_argument('--api-url')
    parser.add_argument('--sandbox', type=uuid.UUID)
    parser.add_argument('--confirm-nonproduction', action='store_true')
    parser.add_argument('--allow-insecure-localhost', action='store_true')
    parser.add_argument('--pairs', type=int, default=3)
    parser.add_argument('--gomaxprocs', type=int, default=4)
    parser.add_argument('--timeout-seconds', type=int, default=840)
    args = parser.parse_args(arguments)
    if not 1 <= args.pairs <= 20 or not 1 <= args.gomaxprocs <= 32 or not 10 <= args.timeout_seconds <= 840:
        parser.error('pair/worker/timeout limit exceeded')
    if args.host_only:
        if args.cli or args.api_url or args.sandbox or args.confirm_nonproduction or args.allow_insecure_localhost:
            parser.error('--host-only cannot include API/guest options')
    elif not (args.cli and args.api_url and args.sandbox and args.confirm_nonproduction):
        parser.error('paired measurement needs --cli, --api-url, --sandbox and --confirm-nonproduction')
    else:
        try:
            validate_nonproduction_url(args.api_url, args.allow_insecure_localhost)
        except ValueError as error:
            parser.error(str(error))
    repo = args.repo.resolve(strict=True)
    try:
        validate_output_location(args.output, repo, args.go_sdk, args.module_cache)
    except (OSError, ValueError) as error:
        parser.error(str(error))
    args.output.mkdir(mode=0o700)
    output = args.output.resolve()
    record = {'schema_version': 1, 'workload': 'darkbloom_sandbox_ci_v1', 'status': 'in_progress',
              'started_at': dt.datetime.now(dt.timezone.utc).isoformat(), 'host': platform.uname()._asdict(),
              'sandbox_id': str(args.sandbox) if args.sandbox else None, 'pairs': [], 'production_ready': False,
              'not_measured': ['cold VM boot', 'two-VM contention', 'inference coexistence'],
              'method': 'Every sample uses a new GOCACHE and verified identical SDK/vendor/source bytes. Package build parallelism is 1; compiler/test GOMAXPROCS is explicit. Input verification warms filesystem cache; OS page cache is not flushed. Alternating host-first/guest-first pairs. Inner compile/test time is separate from API wall time.'}
    evidence = output / 'measurements.json'
    try:
        bundle = output / 'bundle'
        bundle.mkdir(mode=0o700)
        manifest = prepare_bundle(repo, args.revision, args.go_sdk, args.module_cache, bundle, args.gomaxprocs)
        manifest_hash = digest(bundle / 'manifest.json')
        record.update(manifest=manifest, manifest_sha256=manifest_hash)
        write_json(evidence, record)
        prepared = json.loads(command([bundle / 'runner', 'prepare', '--root', bundle, '--manifest-sha256', manifest_hash],
                                      env={'PATH': '/usr/bin:/bin'}, log=output / 'host-prepare.log', timeout=300))
        if prepared.get('status') != 'prepared':
            raise ValueError('host preparation failed')
        remote = None
        if not args.host_only:
            remote = Remote(args.cli.resolve(strict=True), args.api_url, args.sandbox, output, args.allow_insecure_localhost)
            record['cli_sha256'] = digest(args.cli)
            record['sandbox'] = remote.upload_bundle(bundle, manifest_hash)
            record['guest_workspace_directory'] = remote.root
        sides = ['host'] if args.host_only else ['host', 'guest']
        for index in range(args.pairs):
            order = sides if index % 2 == 0 else list(reversed(sides))
            pair = {'index': index, 'order': order}
            for side in order:
                run_id = uuid.uuid4().hex
                if side == 'host':
                    started = time.monotonic()
                    raw = command([bundle / 'runner', 'run', '--root', bundle, '--manifest-sha256', manifest_hash,
                                   '--run-id', run_id, '--timeout-seconds', args.timeout_seconds],
                                  env={'PATH': '/usr/bin:/bin'}, log=output / f'{run_id}-host.log', timeout=args.timeout_seconds + 60)
                    sample = json.loads(raw)
                    sample['caller_wall_seconds'] = time.monotonic() - started
                    expected = bundle / 'runs' / run_id / 'evidence.tar.gz'
                    if digest(expected) != sample.get('evidence_sha256'):
                        raise ValueError('host raw evidence digest mismatch')
                else:
                    sample = remote.sample(manifest_hash, run_id, args.timeout_seconds)
                    expected = Path(sample['downloaded_evidence'])
                if sample.get('run_id') != run_id:
                    raise ValueError('runner returned a different sample identity')
                pair[side] = validate_sample(sample, manifest_hash, manifest)
                verify_evidence_archive(expected, sample)
                record['partial_pair'] = pair
                write_json(evidence, record)
            record['pairs'].append(pair)
            record.pop('partial_pair', None)
            write_json(evidence, record)
            print(f'completed CI pair {index + 1}/{args.pairs}', flush=True)
        if args.host_only:
            record['status'] = 'host_workload_only'
            record['not_measured'].append('all VM CI performance')
        else:
            record['summary'] = summarize(record['pairs'])
            record['status'] = 'measured'
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError, KeyboardInterrupt) as error:
        record['status'] = 'failed'
        record['error'] = str(error)
    finally:
        record['finished_at'] = dt.datetime.now(dt.timezone.utc).isoformat()
        write_json(evidence, record)
    print(json.dumps({'status': record['status'], 'evidence': str(evidence)}))
    return 1 if record['status'] == 'failed' else 0


if __name__ == '__main__':
    raise SystemExit(main())
