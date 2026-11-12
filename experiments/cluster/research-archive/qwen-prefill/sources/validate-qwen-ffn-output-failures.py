"""Bounded native CBv2 failure checks. Run only under the GPU orchestrator.

No real checkpoint, SSH, RDMA or performance qualification is involved. This
driver deliberately bypasses the controller only for native disagreement tests.
"""

import argparse
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import threading
import time
import uuid


REPO = Path('/Users/developer/DarkbloomDev/d-inference')
CLUSTER = REPO / 'experiments/cluster'
BUNDLE = REPO.parent / 'cluster-research/runs/qwen-ffn-output-precision-20260913/bundle'
sys.path.insert(0, str(CLUSTER))
from runtime.artifacts import file_sha256
from runtime.configuration import loopback_addresses, validate
from runtime.persistent import PersistentCohort, PersistentCohortError
from runtime.persistent_io import FrameIO, canonical
from runtime import persistent_protocol as protocol


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, allow_nan=False) + '\n')
    path.chmod(0o600)


def spec_for(partition, timeout=20):
    return validate(dict(schema_version=1,
        backend='solo' if partition == 'solo' else 'loopback-test',
        partition='ffn' if partition == 'solo' else partition,
        ranks=[dict(location='local') for _ in range(1 if partition == 'solo' else 2)],
        workload=dict(synthetic=True, synthetic_profile='tiny', synthetic_dtype='float32',
                      execution_path='cbv2-contiguous', ffn_output_precision='float32', seed=7), timeout_seconds=timeout))


def require_dead(pids):
    for pid in pids:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            continue
        raise AssertionError(f'Owned process {pid} survived retirement')


def source_snapshot(output):
    entries = []
    names = subprocess.check_output(['rg', '--files', 'experiments/cluster'],
                                    cwd=REPO, text=True).splitlines()
    for name in sorted(names):
        source = REPO / name
        target = output / 'source' / source.relative_to(CLUSTER)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
        target.chmod(0o400)
        entries.append(dict(path=name, size_bytes=target.stat().st_size,
                            sha256=file_sha256(target)))
    path = output / 'source-manifest.json'
    write_json(path, entries)
    shutil.copyfile(Path(__file__), output / Path(__file__).name)
    return file_sha256(path), entries


def bundle_identity():
    for name in ('cluster-inference', 'mlx.metallib', 'mlx-swift-lm_MLXLMCommon.bundle'):
        require((BUNDLE / name).exists(), f'Missing immutable bundle resource: {name}')
    return [dict(path=path.relative_to(BUNDLE).as_posix(), size_bytes=path.stat().st_size,
                 sha256=file_sha256(path))
            for path in sorted(BUNDLE.rglob('*')) if path.is_file()]


def cancellation(output, partition):
    cohort = PersistentCohort(spec_for(partition), BUNDLE, output / ('cancel-' + partition))
    started = time.monotonic()
    try:
        ready = cohort.start()
        require(all(r['version'] == 5 and r['identity']['executionPath'] == 'cbv2-contiguous'
                    for r in ready), 'Cancellation cohort advertised the wrong protocol/path')
        workers = cohort.workerPIDs
        # Read-only lifecycle inspection of the supervisors the client owns;
        # native PIDs are independently attested in validated ready frames.
        supervisors = [process.pid for process in cohort._processes]
        epoch = cohort.epoch
        delivered, cancellation_times = [], []

        def cancel_first(step, token):
            delivered.append([step, token])
            cancellation_times.append(time.monotonic())
            cohort.cancel()

        try:
            cohort.infer('cancel-cbv2', [3 + (i * 17 + 7) % 253 for i in range(65)],
                         4096, 32, timeout_seconds=15, on_token=cancel_first)
        except PersistentCohortError:
            pass
        else:
            raise AssertionError('Cancelled CBv2 inference returned success')
        completed = time.monotonic()
        require(cohort.epoch is None and cohort.state == 'failed', 'Epoch was not fenced')
        require(len(delivered) == 1 and delivered[0][0] == 0,
                'Expected exactly the first agreed token before cancellation')
        require_dead(workers + supervisors)
        try:
            cohort.infer('forbidden-reuse', [3], 1, 1)
        except PersistentCohortError:
            pass
        else:
            raise AssertionError('Fenced CBv2 epoch was reused')
        session = json.loads((cohort.output / 'session.json').read_text())
        require(session['state'] == 'failed' and session['requests'][-1]['status'] == 'failed',
                'Retired request manifest was left active')
        result = dict(partition=partition, epoch=epoch, ready=ready,
            worker_pids=workers, supervisor_pids=supervisors, delivered=delivered,
            total_seconds=completed - started,
            cancellation_to_reaped_seconds=completed - cancellation_times[0],
            all_native_workers_and_supervisors_reaped=True, epoch_reuse_rejected=True,
            session_sha256=file_sha256(cohort.output / 'session.json'))
        print(f'cancel {partition}: all workers/supervisors reaped; epoch reuse rejected', flush=True)
        return result
    finally:
        cohort.close()


def environment(rank=None, hosts=None):
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(('MLX_', 'JACCL_', 'DARKBLOOM_'))}
    env['DARKBLOOM_BF16_WEIGHTS'] = '1'
    if rank is not None:
        env.update(MLX_RANK=str(rank), MLX_HOSTFILE=str(hosts))
    return env


@contextmanager
def native_processes(directory, commands, environments):
    """Bound every pipe read and retire groups even if their leader already died."""
    directory.mkdir(mode=0o700)
    processes, ranks = [], []
    io = None
    try:
        for rank, (arguments, env) in enumerate(zip(commands, environments)):
            target = directory / f'rank-{rank}'
            target.mkdir(mode=0o700)
            ranks.append(target)
            write_json(target / 'launch.json', dict(arguments=arguments,
                environment={k: env[k] for k in env if k.startswith(('MLX_', 'DARKBLOOM_'))}))
            with (target / 'stderr.log').open('wb') as stderr:
                (target / 'stderr.log').chmod(0o600)
                processes.append(subprocess.Popen([str(BUNDLE / 'cluster-inference')] + arguments,
                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=stderr,
                    env=env, cwd=BUNDLE, start_new_session=True, bufsize=0))
        io = FrameIO(processes, ranks, threading.Event())
        yield processes, ranks, io
    finally:
        # Signal every owned group, including groups whose leader has exited;
        # this also handles an unexpected native descendant holding a pipe open.
        for process in processes:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        for process in processes:
            process.wait(timeout=5)
        if io is not None:
            io.close()
        else:
            for process in processes:
                for pipe in (process.stdin, process.stdout):
                    if pipe is not None:
                        pipe.close()
        require_dead([process.pid for process in processes])


def drain_until_exit(processes, io, deadline):
    while not (all(p.poll() is not None for p in processes) and all(io.eof)):
        io.pump(deadline)
    require(not any(io.buffers), 'Native output ended with an incomplete frame')


def pair_arguments(epoch, ffn_output_precision):
    return ['--mode', 'worker-tp', '--synthetic', '--synthetic-profile', 'tiny',
            '--synthetic-dtype', 'float32', '--seed', '7', '--transport', 'loopback-test',
            '--partition', 'full', '--execution-path', 'cbv2-contiguous', '--ffn-output-precision', ffn_output_precision,
            '--epoch', epoch, '--timeout-seconds', '15']


def disagreement(output, identity_mismatch):
    name = 'identity-mismatch' if identity_mismatch else 'command-mismatch'
    hosts = output / (name + '-hosts.json')
    write_json(hosts, loopback_addresses())
    epoch = uuid.uuid4().hex
    paths = ['native', 'float32'] if identity_mismatch else ['float32'] * 2
    commands = [pair_arguments(epoch, path) for path in paths]
    envs = [environment(rank, hosts) for rank in range(2)]
    with native_processes(output / name, commands, envs) as (processes, ranks, io):
        ready, requests = [], []
        if not identity_mismatch:
            spec = spec_for('full', timeout=15)
            deadline = time.monotonic() + 20
            ready = [protocol.ready(io.receive(rank, deadline), epoch, rank, spec)
                     for rank in range(2)]
            require(ready[0]['identity'] == ready[1]['identity'], 'Initial rank identities differ')
            require([r['pid'] for r in ready] == [p.pid for p in processes], 'Ready PID differs')
            io.require_idle()
            for rank, process in enumerate(processes):
                request = dict(version=5, type='infer', epoch=epoch, sequence=1,
                    requestID='mismatched-prompt', prompt=[3, 7 + rank, 11], outputTokens=2,
                    chunkSize=2, timeoutSeconds=5, captureLogits=False)
                payload = canonical(request) + b'\n'
                require(len(payload) < 512, 'Direct command exceeds atomic small-pipe bound')
                require(os.write(process.stdin.fileno(), payload) == len(payload), 'Short command write')
                requests.append(request)
            write_json(output / name / 'requests.json', requests)
        drain_until_exit(processes, io, time.monotonic() + (20 if identity_mismatch else 10))
        records = []
        for rank, (process, target) in enumerate(zip(processes, ranks)):
            error = (target / 'stderr.log').read_text()
            require(process.returncode == 1 and 'Ranks disagree' in error,
                    f'{name} rank{rank} failed for an unexpected reason: {error}')
            require(not io.frames[rank], f'{name} rank{rank} emitted an unexpected protocol frame')
            records.append(dict(rank=rank, pid=process.pid, exit_code=process.returncode,
                stdout_sha256=file_sha256(target / 'stdout.jsonl'),
                stderr_sha256=file_sha256(target / 'stderr.log'),
                no_ready=identity_mismatch, no_accepted_or_token=True))
        result = dict(epoch=epoch, ffn_output_precisions=paths, ready=ready, ranks=records,
                      request_sha256=[protocol.hash_frame(x) for x in requests])
    print(f'{name}: both ranks rejected before ' + ('ready' if identity_mismatch else 'accepted'), flush=True)
    return result


def unsupported_cli(output):
    cases = [('gemma-moe', 'cbv2-contiguous'), ('gemma-moe-w8', 'cbv2-contiguous'),
             ('qwen-moe', 'cbv2-contiguous'), ('tiny', 'cbv2-paged')]
    results = []
    for profile, path in cases:
        arguments = ['--mode', 'worker', '--synthetic', '--synthetic-profile', profile,
                     '--execution-path', path, '--epoch', uuid.uuid4().hex,
                     '--timeout-seconds', '5']
        directory = output / ('unsupported-' + profile + '-' + path)
        with native_processes(directory, [arguments], [environment()]) as (processes, ranks, io):
            drain_until_exit(processes, io, time.monotonic() + 7)
            error = (ranks[0] / 'stderr.log').read_text()
            expected = ('Execution path must be ordinary or cbv2-contiguous' if path == 'cbv2-paged'
                        else 'cbv2-contiguous requires dense Qwen baseline or cooperative execution')
            require(processes[0].returncode == 1 and expected in error,
                    f'Unexpected unsupported-profile rejection: {error}')
            require(not io.frames[0], 'Unsupported path emitted a ready/report frame')
            results.append(dict(profile=profile, execution_path=path, exit_code=1,
                no_ready_or_report=True, rejected_at_cli_validation=True,
                stderr_sha256=file_sha256(ranks[0] / 'stderr.log')))
    print('unsupported CLI: Gemma mixed/W8, Qwen MoE and unknown path rejected before ready', flush=True)
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path, help='New output directory outside the repository')
    args = parser.parse_args()
    output = args.output.resolve()
    require(not output.is_relative_to(REPO) and not output.exists(), 'Output must be new and outside Git')
    require(protocol.VERSION == 5, 'This receipt requires current worker protocol5/report schema9')
    output.mkdir(mode=0o700, parents=True)
    receipt = dict(schema_version=1, report_schema_version=8, worker_protocol_version=5,
        bundle=str(BUNDLE), driver_sha256=file_sha256(Path(__file__)), synthetic_only=True,
        performance_qualification=False, numerical_qualification=False, status='running')
    source_entries = []
    try:
        receipt['source_manifest_sha256'], source_entries = source_snapshot(output)
        receipt['bundle_files'] = bundle_identity()
        receipt['bundle_files_sha256'] = hashlib.sha256(canonical(receipt['bundle_files'])).hexdigest()
        receipt['binary_sha256'] = file_sha256(BUNDLE / 'cluster-inference')
        write_json(output / 'receipt.json', receipt)
        receipt['cancellation'] = []
        for partition in ('solo', 'ffn', 'full'):
            receipt['cancellation'].append(cancellation(output, partition))
            write_json(output / 'receipt.json', receipt)
        receipt['native_command_mismatch'] = disagreement(output, False)
        write_json(output / 'receipt.json', receipt)
        receipt['native_ffn_output_precision_mismatch'] = disagreement(output, True)
        receipt['unsupported_cli'] = unsupported_cli(output)
        require(bundle_identity() == receipt['bundle_files'], 'Immutable bundle changed during validation')
        for entry in source_entries:
            require(file_sha256(REPO / entry['path']) == entry['sha256'],
                    'Runtime/source changed during validation: ' + entry['path'])
        receipt['source_and_bundle_unchanged'] = True
        receipt['status'] = 'passed'
    except BaseException as error:
        receipt.update(status='failed', failure=f'{type(error).__name__}: {error}')
        raise
    finally:
        write_json(output / 'receipt.json', receipt)
    print('CBv2 failure checks passed; receipt:', output / 'receipt.json', flush=True)


def interrupted(_signal, _frame):
    raise KeyboardInterrupt()


if __name__ == '__main__':
    # Python unwinding executes all cohort/group cleanup on external termination.
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGHUP, interrupted)
    main()
