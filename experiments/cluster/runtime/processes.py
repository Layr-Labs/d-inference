"""Stage rank bundles and supervise a cohort with one cancellation decision."""

import concurrent.futures
import json
import os
from pathlib import Path
import shlex
import signal
import subprocess
import sys
import time

from .configuration import rank_configuration


def ssh_command(host, command):
    return ['ssh', '-T', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5',
            '-o', 'ServerAliveInterval=5', '-o', 'ServerAliveCountMax=2', host, command]


def ssh(host, arguments, **kwargs):
    return subprocess.run(ssh_command(host, shlex.join(arguments)), check=True, **kwargs)


def scp(source, destination):
    subprocess.run(['scp', '-rq', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5',
                    source, destination], check=True, timeout=120)


def stage(spec, index, output, bundle_hash, hostfile, run_id):
    rank = spec['ranks'][index]
    local = output / f'rank-{index}'
    local.mkdir(mode=0o700)
    host = rank.get('host') if rank['location'] == 'ssh' else None
    if host:
        home = ssh(host, ['/usr/bin/python3', '-c',
                         'from pathlib import Path; print(Path.home())'],
                   capture_output=True, text=True, timeout=10).stdout.strip()
        if not home.startswith('/') or '\n' in home:
            raise ValueError('Remote host did not return one absolute home directory')
        directory = Path(home) / 'DarkbloomDev' / 'cluster-runs' / run_id / f'rank-{index}'
        ssh(host, ['mkdir', '-p', '-m', '700', str(directory)], timeout=10)
        scp(str(output / 'bundle'), f'{host}:{shlex.quote(str(directory))}/')
        bundle = directory / 'bundle'
    else:
        directory, bundle = local, output / 'bundle'
    config = rank_configuration(spec, index, bundle, bundle_hash, hostfile)
    config_path = local / 'rank.json'
    config_path.write_text(json.dumps(config, indent=2) + '\n')
    config_path.chmod(0o600)
    if host:
        scp(str(config_path), f'{host}:{shlex.quote(str(directory / "rank.json"))}')
    return dict(rank=index, host=host, directory=str(directory), local=str(local),
                bundle=str(bundle))


def start(rank):
    command = [sys.executable if rank['host'] is None else '/usr/bin/python3',
               str(Path(rank['bundle']) / 'rank_worker.py'),
               str(Path(rank['directory']) / 'rank.json')]
    if rank['host']:
        command = ssh_command(rank['host'], shlex.join(command))
    local = Path(rank['local'])
    with (local / 'stdout.jsonl').open('wb') as stdout, (local / 'stderr.log').open('wb') as stderr:
        return subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=stdout,
                                stderr=stderr, start_new_session=True)


def request_cancel(rank):
    cancel = Path(rank['directory']) / 'cancel'
    try:
        if rank['host']:
            ssh(rank['host'], ['touch', str(cancel)], timeout=10)
        else:
            cancel.touch()
    except (OSError, subprocess.SubprocessError):
        # The supervisor signal handler and native alarm remain independent bounds.
        pass


def stop_processes(ranks, processes):
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(ranks)) as pool:
        list(pool.map(request_cancel, ranks))
    for process in processes:
        if process.poll() is None:
            process.terminate()
    deadline = time.monotonic() + 3
    for process in processes:
        try:
            process.wait(timeout=max(0.01, deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()


def run_cohort(ranks, timeout):
    processes, reason = [], None
    deadline = time.monotonic() + timeout
    try:
        for rank in ranks:
            processes.append(start(rank))
        while True:
            codes = [process.poll() for process in processes]
            if any(code is not None and code != 0 for code in codes):
                reason = 'rank_failed'
                break
            if all(code is not None for code in codes):
                break
            if time.monotonic() >= deadline:
                reason = 'cohort_deadline'
                break
            time.sleep(0.1)
    finally:
        if any(process.poll() is None for process in processes):
            stop_processes(ranks, processes)
    return dict(exit_codes=[p.returncode for p in processes], cancellation_reason=reason)


def collect_logits(rank):
    if rank['host']:
        scp(f'{rank["host"]}:{shlex.quote(str(Path(rank["directory"]) / "logits.json"))}',
            str(Path(rank['local']) / 'logits.json'))
