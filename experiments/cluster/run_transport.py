#!/usr/bin/env python3
"""Stage and run a bounded, two-rank transport probe over existing SSH access."""

import argparse
import base64
import concurrent.futures
import datetime
import hashlib
import ipaddress
import json
import pathlib
import shlex
import shutil
import subprocess
import sys
import tempfile
import uuid


REMOTE_RUNNER = """
import base64, json, os, pathlib, signal, subprocess, sys
cfg = json.loads(base64.b64decode(sys.argv[1]))
directory = pathlib.Path.home() / cfg['directory']
devices = directory / 'devices.json'
devices.write_text(json.dumps(cfg['devices']))
env = os.environ.copy()
env.update(JACCL_RANK=str(cfg['rank']), JACCL_COORDINATOR=cfg['coordinator'],
           JACCL_IBV_DEVICES=str(devices))
env.pop('JACCL_RING', None)
env.pop('MLX_JACCL_RING', None)
child = None
def interrupted(signum, _frame):
    raise SystemExit(128 + signum)
for signum in (signal.SIGHUP, signal.SIGTERM, signal.SIGINT):
    signal.signal(signum, interrupted)
try:
    child = subprocess.Popen([str(directory / 'cluster-transport-probe'), *cfg['args']],
                             env=env, cwd=directory, start_new_session=True)
    try:
        status = child.wait(timeout=cfg['timeout'])
    except subprocess.TimeoutExpired:
        print('cluster transport probe exceeded remote deadline', file=sys.stderr)
        status = 124
finally:
    # A disconnected SSH session can signal its supervisor. Clean up that
    # supervisor's detached process group before propagating the signal exit.
    for signum in (signal.SIGHUP, signal.SIGTERM, signal.SIGINT):
        signal.signal(signum, signal.SIG_IGN)
    if child is not None:
        if child.poll() is None:
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        child.wait()
sys.exit(status if status >= 0 else 128 - status)
"""

VERIFY_BINARY = """
import hashlib, pathlib, sys
binary = pathlib.Path(sys.argv[1])
actual = hashlib.sha256(binary.read_bytes()).hexdigest()
if actual != sys.argv[2]:
    raise SystemExit('Staged binary SHA-256 does not match the run manifest')
binary.chmod(0o700)
"""


def ssh(host, command, **kwargs):
    return subprocess.run(
        ['ssh', '-T', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', host, command],
        check=True, **kwargs,
    )


def stage(host, directory, binary, digest):
    # Paths are generated here, relative to the authenticated account's home.
    ssh(host, f'mkdir -p -m 700 {shlex.quote(directory)}', timeout=20)
    subprocess.run(
        ['scp', '-q', '-o', 'BatchMode=yes', str(binary),
         f'{host}:{directory}/cluster-transport-probe'], check=True, timeout=90,
    )
    command = shlex.join(['/usr/bin/python3', '-c', VERIFY_BINARY,
                          f'{directory}/cluster-transport-probe', digest])
    ssh(host, command, timeout=20)


def bounded_probe_args(arguments, deadline):
    """Pass exactly one native deadline, no longer than the supervisor's."""
    parser = argparse.ArgumentParser(add_help=False, allow_abbrev=False)
    parser.add_argument('--timeout-seconds', action='append', type=int, default=[])
    native, remaining = parser.parse_known_args(arguments)
    if any(not 1 <= value <= 3600 for value in native.timeout_seconds):
        raise ValueError('probe timeout must be between 1 and 3600 seconds')
    effective = min([deadline, *native.timeout_seconds])
    return [*remaining, '--timeout-seconds', str(effective)]


def run_rank(host, config, output):
    payload = base64.b64encode(json.dumps(config).encode()).decode()
    command = shlex.join(['/usr/bin/python3', '-c', REMOTE_RUNNER, payload])
    with (output / f'rank-{config["rank"]}.jsonl').open('wb') as stdout:
        with (output / f'rank-{config["rank"]}.stderr').open('wb') as stderr:
            try:
                ssh(host, command, stdout=stdout, stderr=stderr,
                    timeout=config['timeout'] + 30)
                return 0
            except subprocess.CalledProcessError as error:
                return error.returncode
            except subprocess.TimeoutExpired:
                return 124


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host', action='append', required=True,
                        help='SSH alias, in rank order; supply exactly twice')
    parser.add_argument('--device', action='append', required=True,
                        help='Each rank\'s connected RDMA device; supply twice')
    parser.add_argument('--coordinator', required=True,
                        help='Rank 0 IPv4 address:unused-port, reachable by both ranks')
    parser.add_argument('--binary', type=pathlib.Path, required=True)
    parser.add_argument('--output', type=pathlib.Path, required=True,
                        help='New directory outside the repository for private raw logs')
    parser.add_argument('--timeout', type=int, default=90)
    parser.add_argument('probe_args', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if len(args.host) != 2 or len(args.device) != 2:
        parser.error('exactly two hosts and devices are required')
    if any(h.startswith('-') or ':' in h or '/' in h for h in args.host):
        parser.error('hosts must be SSH aliases, without path or port syntax')
    if len(set(args.host)) != 2:
        parser.error('the two host aliases must differ')
    try:
        address, port = args.coordinator.rsplit(':', 1)
        ipaddress.IPv4Address(address)
        if not 1 <= int(port) <= 65535:
            raise ValueError('port out of range')
    except ValueError:
        parser.error('coordinator must be a rank 0 IPv4 address:port')
    if not args.binary.is_file() or not 1 <= args.timeout <= 600:
        parser.error('binary must exist and timeout must be between 1 and 600 seconds')
    args.output = args.output.resolve()
    repository = pathlib.Path(__file__).resolve().parents[2]
    if args.output.is_relative_to(repository):
        parser.error('output must be outside the repository, including through symlinks')
    probe_args = args.probe_args
    if probe_args[:1] == ['--']:
        probe_args = probe_args[1:]
    try:
        probe_args = bounded_probe_args(probe_args, args.timeout)
    except ValueError as error:
        parser.error(str(error))
    args.output.mkdir(parents=True, exist_ok=False)
    args.output.chmod(0o700)
    directory = f'DarkbloomDev/cluster-runs/{uuid.uuid4().hex}'
    common = dict(directory=directory, coordinator=args.coordinator,
                  devices=[[None, args.device[0]], [args.device[1], None]],
                  args=probe_args, timeout=args.timeout)
    manifest = dict(started_at=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                    hosts=args.host, binary=str(args.binary.resolve()),
                    **common)
    manifest_path = args.output / 'run.json'
    manifest_path.write_text(json.dumps(manifest, indent=2) + '\n')
    try:
        # A rebuild may replace the original binary during staging. Both ranks
        # receive this private snapshot, whose hash is checked remotely as well.
        with tempfile.TemporaryDirectory(prefix='darkbloom-transport-') as temporary:
            snapshot = pathlib.Path(temporary) / 'cluster-transport-probe'
            shutil.copyfile(args.binary, snapshot)
            snapshot.chmod(0o500)
            digest = hashlib.sha256(snapshot.read_bytes()).hexdigest()
            manifest['binary_sha256'] = digest
            manifest_path.write_text(json.dumps(manifest, indent=2) + '\n')
            with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
                list(pool.map(lambda host: stage(host, directory, snapshot, digest), args.host))
                results = list(pool.map(
                    lambda rank: run_rank(args.host[rank], dict(rank=rank, **common), args.output),
                    range(2),
                ))
        manifest['exit_codes'] = results
    except (OSError, subprocess.SubprocessError) as error:
        manifest['launcher_error'] = str(error)
        raise
    finally:
        manifest['finished_at'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        manifest_path.write_text(json.dumps(manifest, indent=2) + '\n')
    print(json.dumps({'output': str(args.output), 'exit_codes': results}))
    return 0 if results == [0, 0] else 1


if __name__ == '__main__':
    sys.exit(main())
