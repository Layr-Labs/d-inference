#!/usr/bin/env python3
"""Measure paired host/guest CPU execution separately from API delivery latency.

Use an explicitly selected, ready non-production sandbox on this physical Mac.
This tool writes one uniquely named benchmark binary to its workspace. It does
not create/delete sandboxes, renew leases, or change host/provider services.
"""
import argparse
import datetime as dt
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import statistics
import subprocess
import time
import uuid

SOURCE = Path(__file__).resolve().parents[1] / 'Benchmarks' / 'cpu.c'


def digest(path):
    with path.open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def run(command, timeout=960):
    started = time.monotonic()
    process = subprocess.run([str(part) for part in command], capture_output=True,
                             text=True, timeout=timeout)
    if process.returncode:
        raise RuntimeError(f'benchmark step failed with exit {process.returncode}: '
                           + process.stderr[-4096:])
    return process.stdout, time.monotonic() - started


def validate_sample(sample, workers, iterations):
    if (sample.get('schema_version') != 1
            or sample.get('workload') != 'integer_recurrence_v1'
            or sample.get('workers') != workers or sample.get('iterations') != iterations):
        raise ValueError('benchmark workload identity mismatch')
    elapsed = sample.get('elapsed_seconds')
    if isinstance(elapsed, bool) or not isinstance(elapsed, (int, float)) or not math.isfinite(elapsed) or elapsed <= 0:
        raise ValueError('benchmark elapsed time must be positive and finite')
    checksum = sample.get('checksum', '')
    if len(checksum) != 16 or any(c not in '0123456789abcdef' for c in checksum):
        raise ValueError('benchmark checksum is invalid')
    return sample


def summarize(pairs):
    ratios = []
    for pair in pairs:
        host, guest = pair['host'], pair['guest']
        if any(host[field] != guest[field] for field in
               ['schema_version', 'workload', 'workers', 'iterations', 'checksum']):
            raise ValueError('host/guest workload or result mismatch')
        ratios.append(guest['elapsed_seconds'] / host['elapsed_seconds'])
    if not ratios:
        raise ValueError('no complete host/guest pairs')
    ordered = sorted(ratios)
    return {
        'pair_count': len(pairs),
        'median_guest_over_host': statistics.median(ratios),
        'p95_guest_over_host': ordered[math.ceil(0.95 * len(ordered)) - 1],
        'median_overhead_percent': (statistics.median(ratios) - 1) * 100,
        'median_host_execution_seconds': statistics.median(p['host']['elapsed_seconds'] for p in pairs),
        'median_guest_execution_seconds': statistics.median(p['guest']['elapsed_seconds'] for p in pairs),
        'median_guest_api_wall_seconds': statistics.median(p['guest']['caller_wall_seconds'] for p in pairs),
    }


def write_record(path, record):
    temporary = path.with_suffix('.tmp')
    with temporary.open('w') as output:
        json.dump(record, output, indent=2, allow_nan=False)
        output.write('\n')
        output.flush()
        os.fsync(output.fileno())
    temporary.replace(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--cli', type=Path)
    parser.add_argument('--sandbox', type=uuid.UUID)
    parser.add_argument('--host-only', action='store_true', help='smoke-test workload without claiming VM performance')
    parser.add_argument('--allow-insecure-localhost', action='store_true')
    parser.add_argument('--pairs', type=int, default=20)
    parser.add_argument('--workers', type=int, default=4)
    parser.add_argument('--iterations', type=int, default=100_000_000)
    args = parser.parse_args()
    if not 1 <= args.workers <= 32 or not 1 <= args.iterations <= 2_000_000_000 or not 1 <= args.pairs <= 100:
        parser.error('workers, iterations or pairs exceed workload bounds')
    if not args.host_only and (not args.cli or not args.sandbox):
        parser.error('paired measurements require --cli and --sandbox')
    if args.host_only and (args.cli or args.sandbox):
        parser.error('--host-only cannot be combined with --cli or --sandbox')
    if not args.output.is_absolute() or args.output.exists():
        parser.error('--output must be a new absolute directory')
    args.output.mkdir(mode=0o700)
    record = {
        'schema_version': 1, 'started_at': dt.datetime.now(dt.timezone.utc).isoformat(),
        'host': platform.uname()._asdict(), 'sandbox_id': str(args.sandbox) if args.sandbox else None,
        'source_sha256': digest(SOURCE), 'parameters': {'workers': args.workers, 'iterations': args.iterations},
        'warmups': [], 'pairs': [], 'status': 'in_progress', 'production_ready': False,
        'not_measured': ['CI build workloads', 'two-VM contention', 'inference coexistence', 'cold start'],
        'method': 'One warmup per side, then alternating host-first and guest-first pairs; identical uploaded binary.',
    }
    output = args.output / 'measurements.json'
    binary = args.output / 'cpu'
    cli = [args.cli, '--json']
    if args.allow_insecure_localhost:
        cli.append('--allow-insecure-localhost')
    remote = 'benchmark-' + uuid.uuid4().hex
    guest_binary = '/workspace/' + remote

    def guest_command(arguments):
        raw, wall = run(cli + ['exec', '--timeout', '900', str(args.sandbox), '--'] + arguments)
        job = json.loads(raw)
        if job.get('state') != 'succeeded' or job.get('exit_code') != 0 or job.get('output_truncated'):
            raise RuntimeError('guest benchmark command failed or output was truncated')
        return job['stdout'], wall, job['id']

    def sample(side):
        if side == 'host':
            raw, wall = run([binary, args.workers, args.iterations])
            command_id = None
        else:
            raw, wall, command_id = guest_command([guest_binary, str(args.workers), str(args.iterations)])
        result = validate_sample(json.loads(raw), args.workers, args.iterations)
        result.update(caller_wall_seconds=wall, command_id=command_id)
        return result

    try:
        compiler, _ = run(['xcrun', 'clang', '--version'], timeout=30)
        record['compiler'] = compiler.strip()
        run(['xcrun', 'clang', '-O3', '-std=c11', '-pthread', SOURCE, '-o', binary], timeout=120)
        record['binary_sha256'] = digest(binary)
        if not args.host_only:
            record['cli_sha256'] = digest(args.cli)
            upload, _ = run(cli + ['upload', str(args.sandbox), binary, remote])
            record['upload'] = json.loads(upload)
            actual, _, _ = guest_command(['/usr/bin/shasum', '-a', '256', guest_binary])
            if actual.split()[0] != record['binary_sha256']:
                raise ValueError('uploaded benchmark binary digest mismatch')
            guest_command(['/bin/chmod', '700', guest_binary])
        sides = ['host'] if args.host_only else ['host', 'guest']
        for side in sides:
            record['warmups'].append({'side': side, **sample(side)})
            write_record(output, record)
        for index in range(args.pairs):
            order = sides if index % 2 == 0 else list(reversed(sides))
            pair = {'index': index, 'order': order}
            for side in order:
                pair[side] = sample(side)
            record['pairs'].append(pair)
            write_record(output, record)
            print(f'completed pair {index + 1}/{args.pairs}', flush=True)
        if args.host_only:
            record['status'] = 'host_workload_only'
            record['not_measured'].append('all VM performance')
        else:
            record['summary'] = summarize(record['pairs'])
            record['status'] = 'measured'
            if record['summary']['median_host_execution_seconds'] < 0.25:
                record['measurement_caution'] = 'Increase iterations: workload duration is too short for a stable comparison.'
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError, KeyboardInterrupt) as error:
        record['status'] = 'failed'
        record['error'] = str(error)
    finally:
        record['finished_at'] = dt.datetime.now(dt.timezone.utc).isoformat()
        write_record(output, record)
    print(json.dumps({'evidence': str(output), 'status': record['status']}))
    return 1 if record['status'] == 'failed' else 0


if __name__ == '__main__':
    raise SystemExit(main())
