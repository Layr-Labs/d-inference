#!/usr/bin/env python3
"""Root-owned single native tiny check; archive, bound, monitor and reap it."""
import argparse
from datetime import datetime, timezone
from decimal import Decimal
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import time
import uuid
sys.dont_write_bytecode = True

ROOT = Path('/Users/developer/DarkbloomDev')
REPO = ROOT / 'd-inference'
RESEARCH = ROOT / 'cluster-research'
HELPER = RESEARCH / 'remote-solo-prefill-launcher-draft/prefill_compute_archive.py'
HELPER_SHA = 'dde031892fcec8c98b70f4b300e1ef1aaca309547c400b1a50d85e791e069930'
REFERENCE_HELPER = Path(__file__).with_name('owned_bundle_reference.py')
REFERENCE_HELPER_SHA = 'c4832e457307f683f5aff55cafefe6feeeaf6a69ad1be2dc220325f96f5da8a4'
ENVIRONMENT = {'DARKBLOOM_BF16_WEIGHTS': '1', 'DARKBLOOM_CBV2_ATTN_QUERY_BLOCK': '128', 'MLX_ENABLE_TF32': '1'}


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def require(value, message):
    if not value:
        raise ValueError(message)


def now():
    return datetime.now(timezone.utc).isoformat()


def read_command(args):
    result = subprocess.run(args, capture_output=True, text=True, timeout=3, check=True)
    require(not result.stderr and len(result.stdout.encode()) <= 2 * 1024**2, 'Unexpected bounded observation output')
    return result.stdout


def sample(native_pid=None):
    memory = read_command(['/usr/sbin/sysctl', '-n', 'kern.memorystatus_vm_pressure_level', 'vm.swapusage'])
    vm = read_command(['/usr/bin/vm_stat'])
    page = re.search(r'page size of (\d+) bytes', vm)
    free = re.search(r'Pages free:\s+(\d+)\.', vm)
    used = re.search(r'used\s*=\s*([0-9.]+)([MG])', memory)
    require(page and free and used, 'Cannot parse resource observation')
    swap = Decimal(used.group(1)) * (1024**2 if used.group(2) == 'M' else 1024**3)
    result = dict(timestampUTC=now(), monotonicSeconds=time.monotonic(),
        pressureLevel=int(memory.splitlines()[0]), reportedSwapBytes=str(swap),
        actualFreeBytes=int(page.group(1)) * int(free.group(1)), rawMemory=memory, rawVMStat=vm,
        nativeRSSBytes=None, missingRSSIsNotZero=True)
    if native_pid is not None:
        p = subprocess.run(['/bin/ps', '-p', str(native_pid), '-o', 'pid=,pgid=,rss=,command='],
                           capture_output=True, text=True, timeout=3)
        require(p.returncode in (0, 1) and not p.stderr and len(p.stdout.encode()) <= 65536, 'Invalid owned process observation')
        if p.stdout.strip():
            fields = p.stdout.strip().split(None, 3)
            require(len(fields) == 4 and int(fields[0]) == native_pid, 'Owned process observation changed PID')
            result.update(nativePID=native_pid, nativePGID=int(fields[1]), nativeRSSBytes=int(fields[2]) * 1024,
                          nativeCommand=fields[3])
    return result


def require_resources(observation, baseline):
    require(observation['pressureLevel'] <= 2, 'Memory pressure exceeded the tiny-check gate')
    require(Decimal(observation['reportedSwapBytes']) <= Decimal(baseline['reportedSwapBytes']),
            'Reported swap increased during the tiny check')


def owned_group(pgid):
    raw = read_command(['/bin/ps', '-axo', 'pid=,ppid=,pgid=,command='])
    rows = []
    for line in raw.splitlines():
        fields = line.strip().split(None, 3)
        if len(fields) == 4 and int(fields[2]) == pgid:
            rows.append(dict(pid=int(fields[0]), ppid=int(fields[1]), pgid=pgid, command=fields[3]))
    return rows


def stop_owned(process):
    errors = []
    for signum in (signal.SIGTERM, signal.SIGKILL):
        # The group can outlive its original leader. Its identity was allocated
        # by start_new_session; never replace it with a process-name search.
        if process.poll() is not None and not owned_group(process.pid):
            return errors
        try:
            os.killpg(process.pid, signum)
        except ProcessLookupError:
            pass
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if process.poll() is not None and not owned_group(process.pid):
                return errors
            time.sleep(0.05)
    if process.poll() is None:
        errors.append('Native leader was not reaped after TERM/KILL')
    if owned_group(process.pid):
        errors.append('Owned native process group remains after TERM/KILL')
    return errors


def interrupted(signum, _frame):
    raise KeyboardInterrupt('Root tiny check interrupted by signal ' + str(signum))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--expected-native-sha256', required=True)
    parser.add_argument('--workload', choices=['legacy', 'profiled'], required=True)
    parser.add_argument('--reuse-bundle', type=Path)
    parser.add_argument('--release', type=Path)
    parser.add_argument('--expected-bundle-manifest-sha256')
    args = parser.parse_args()
    require((args.reuse_bundle is None) == (args.expected_bundle_manifest_sha256 is None),
            'Bundle reuse requires both path and expected manifest pin')
    if args.reuse_bundle is not None:
        require(re.fullmatch('[0-9a-f]{64}', args.expected_bundle_manifest_sha256), 'Invalid bundle manifest pin')
    out = args.output.resolve()
    require(not out.exists() and out.parent.is_dir() and not out.is_relative_to(REPO), 'Output must be new and outside Git')
    require(re.fullmatch('[0-9a-f]{64}', args.expected_native_sha256), 'Invalid native pin')
    require(sha(HELPER) == HELPER_SHA, 'Frozen archive helper differs')
    release = (args.release.expanduser().resolve(strict=True) if args.release is not None
               else REPO / 'experiments/cluster/inference/.build/release')
    require(sha(release / 'cluster-inference') == args.expected_native_sha256, 'Built native pin differs')
    spec = importlib.util.spec_from_file_location('tiny_check_archive', HELPER)
    archive = importlib.util.module_from_spec(spec); spec.loader.exec_module(archive)
    out.mkdir(mode=0o700)
    receipt = dict(kind='root_guarded_tiny_stage_check', schemaVersion=1, startedAtUTC=now(),
        status='preparing', workload=args.workload, expectedNativeSHA256=args.expected_native_sha256,
        releaseDirectory=str(release),
        nativeExecutionAttempted=False, nativeExecutions=0, nativePID=None, nativeReaped=False,
        nativeExitCode=None, primaryFailure=None, cleanupErrors=[], postRunErrors=[], memorySamples=[],
        arithmeticEnvironment=ENVIRONMENT, initialActualFreeGateBytes=1024**3,
        memoryPolicy='tiny fixtures only; initial actual free>=1GiB; pressure<=2; no new reported swap; native180s/parent195s',
        throughputQualification=False, physicalTwoMachineExecution=False)
    save = lambda: archive.write_json(out / 'receipt.json', receipt)
    save()
    process = None; modules = None; source_manifest = None; bundle_sha = None
    driver_pin = sha(Path(__file__))
    reference_helper = bundle_reference = None
    try:
        shutil.copyfile(Path(__file__), out / Path(__file__).name)
        shutil.copyfile(HELPER, out / 'prefill_compute_archive.py')
        receipt.update(driverSHA256=driver_pin, archiveHelperSHA256=HELPER_SHA)
        initial = sample(); receipt['memorySamples'].append(initial)
        require(initial['actualFreeBytes'] >= 1024**3 and initial['pressureLevel'] <= 2, 'Initial tiny resource admission refused')
        live = read_command(['/bin/ps', '-axo', 'command='])
        require(not any('/cluster-inference ' in line or '/rank_worker.py ' in line for line in live.splitlines()),
                'A native inference experiment is already active')
        source_manifest = archive.archive_sources(REPO / 'experiments/cluster/runtime', out)
        modules = archive.load_archived_runtime(out, uuid.uuid4().hex)
        if args.reuse_bundle is not None:
            require(sha(REFERENCE_HELPER) == REFERENCE_HELPER_SHA, 'Bundle reference helper changed')
            reference_spec = importlib.util.spec_from_file_location('tiny_bundle_reference', REFERENCE_HELPER)
            reference_helper = importlib.util.module_from_spec(reference_spec)
            reference_spec.loader.exec_module(reference_helper)
            shutil.copyfile(REFERENCE_HELPER, out / REFERENCE_HELPER.name)
            bundle_reference = reference_helper.create_reference(args.reuse_bundle, out / 'bundle',
                args.expected_bundle_manifest_sha256, args.expected_native_sha256,
                out / 'source/experiments/cluster/runtime', modules['artifacts'])
            bundle_sha = bundle_reference['manifestSHA256']
            receipt.update(bundleAcquisition='reused_external_reference', bundleReference=bundle_reference,
                           bundleCopiedForThisRun=False, bundleReferenceHelperSHA256=REFERENCE_HELPER_SHA)
        else:
            bundle_sha = modules['bundle'].snapshot(release, out / 'bundle')
        require(sha(out / 'bundle/cluster-inference') == args.expected_native_sha256, 'Archived native differs')
        receipt.update(sourceManifestSHA256=sha(out / 'source-manifest.json'), sourceFileCount=len(source_manifest['files']),
                       bundleManifestSHA256=bundle_sha)
        archive.verify_archive(modules, out, source_manifest, bundle_sha, [])
        if bundle_reference is not None:
            reference_helper.check_reference(out / 'bundle', bundle_reference,
                out / 'source/experiments/cluster/runtime', modules['artifacts'])
        before = sample(); receipt['memorySamples'].append(before); require_resources(before, initial)
        require(before['actualFreeBytes'] >= 1024**3, 'Actual free memory fell below tiny gate before native launch')
        mode, counts = ('qwen-layer-stage-profiled-check', ['8192', '512', '1']) if args.workload == 'profiled' else (
            'qwen-layer-stage-check', ['65', '32', '4'])
        command = [str(out / 'bundle/cluster-inference'), '--mode', mode, '--synthetic',
            '--execution-path', 'cbv2-contiguous', '--prompt-tokens', counts[0], '--chunk-size', counts[1],
            '--decode-tokens', counts[2], '--repeats', '1', '--warmups', '0', '--timeout-seconds', '180']
        environment = {key: value for key, value in os.environ.items() if not key.startswith(('MLX_', 'DARKBLOOM_'))}
        environment.update(ENVIRONMENT)
        receipt.update(command=command, nativeExecutionAttempted=True, status='running'); save()
        with (out / 'stdout.jsonl').open('xb') as stdout, (out / 'stderr.log').open('xb') as stderr:
            process = subprocess.Popen(command, cwd=out / 'bundle', env=environment,
                stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr, start_new_session=True)
            receipt.update(nativePID=process.pid, nativeExecutions=1); save()
            deadline = time.monotonic() + 195
            while process.poll() is None:
                observation = sample(process.pid); receipt['memorySamples'].append(observation)
                require_resources(observation, initial)
                require(time.monotonic() < deadline, 'Parent native deadline exceeded')
                require((out / 'stdout.jsonl').stat().st_size <= 8 * 1024**2 and (out / 'stderr.log').stat().st_size <= 65536,
                        'Native output exceeded its bound')
                save()
                try: process.wait(timeout=0.25)
                except subprocess.TimeoutExpired: pass
            receipt.update(nativeExitCode=process.wait(), nativeReaped=True)
        require(receipt['nativeExitCode'] == 0, 'Native tiny check failed')
        require((out / 'stdout.jsonl').stat().st_size <= 8 * 1024**2 and (out / 'stderr.log').stat().st_size <= 65536,
                'Completed native output exceeded its bound')
        require((out / 'stderr.log').stat().st_size == 0, 'Successful native check emitted stderr')
    except BaseException as error:
        receipt['primaryFailure'] = type(error).__name__ + ': ' + str(error)
    finally:
        if process is not None:
            try:
                receipt['cleanupErrors'].extend(stop_owned(process))
                receipt.update(nativeExitCode=process.poll(), nativeReaped=process.poll() is not None)
            except BaseException as error:
                receipt['cleanupErrors'].append(type(error).__name__ + ': ' + str(error))
        try:
            if process is not None:
                receipt['ownedProcessGroupAfter'] = owned_group(process.pid)
                require(not receipt['ownedProcessGroupAfter'], 'Owned native process group remains live after cleanup')
            after = sample(); receipt['memorySamples'].append(after)
            require_resources(after, receipt['memorySamples'][0])
            if modules and source_manifest and bundle_sha:
                archive.verify_archive(modules, out, source_manifest, bundle_sha, [])
            require(sha(Path(__file__)) == driver_pin and sha(HELPER) == HELPER_SHA, 'Driver source changed')
            for name in ('stdout.jsonl', 'stderr.log'):
                if (out / name).exists():
                    size = (out / name).stat().st_size
                    limit = 8 * 1024**2 if name == 'stdout.jsonl' else 65536
                    receipt[name] = dict(sha256=sha(out / name) if size <= limit else None,
                        sizeBytes=size, hashOmittedBecauseOversized=size > limit)
        except BaseException as error:
            receipt['postRunErrors'].append(type(error).__name__ + ': ' + str(error))
        if bundle_reference is not None:
            try:
                reference_helper.check_reference(out / 'bundle', bundle_reference,
                    out / 'source/experiments/cluster/runtime', modules['artifacts'])
                require(sha(REFERENCE_HELPER) == REFERENCE_HELPER_SHA and
                        sha(out / REFERENCE_HELPER.name) == REFERENCE_HELPER_SHA, 'Bundle reference helper changed')
                receipt['bundleReferenceUnchangedAfterRun'] = True
            except BaseException as error:
                receipt['postRunErrors'].append('bundle_reference_recheck: ' + type(error).__name__ + ': ' + str(error))
        receipt.update(finishedAtUTC=now(), status='completed' if receipt['nativeReaped']
            and receipt['nativeExitCode'] == 0 and not receipt['primaryFailure']
            and not receipt['cleanupErrors'] and not receipt['postRunErrors'] else 'failed')
        save()
    print(json.dumps(dict(status=receipt['status'], receipt=str(out / 'receipt.json'), sha256=sha(out / 'receipt.json'),
        primaryFailure=receipt['primaryFailure'], cleanupErrors=receipt['cleanupErrors'], postRunErrors=receipt['postRunErrors'])))
    return 0 if receipt['status'] == 'completed' else 1


if __name__ == '__main__':
    for signal_number in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(signal_number, interrupted)
    sys.exit(main())
