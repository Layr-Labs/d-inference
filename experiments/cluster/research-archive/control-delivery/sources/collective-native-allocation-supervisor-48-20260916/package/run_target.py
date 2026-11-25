#!/usr/bin/env python3
"""One fixed native allocation case; no model, group or RDMA operation."""
import argparse
import os
from pathlib import Path
import platform
import signal
import sys
import time

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))
from binding_common import canonical, require
from mtp_journal import device_directory, observe as journal_observation, require_empty
from reference_resources import ResourceGate, read_command
from target_contract import JOBS, REMOTE
from target_inputs import Pins, verify_package, write_json
from target_processes import observe as process_observation
from target_supervision import serve
from worker_contract import WorkerSpec
from worker_processes import PipeWorkers, cleanup_error_text


def main(arguments=None):
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('--package-sha256', required=True)
    parser.add_argument('--fixture', choices=sorted(JOBS), required=True)
    parser.add_argument('--attempt', type=int, choices=range(1, 10), default=1)
    args = parser.parse_args(arguments)
    require(str(ROOT) == REMOTE and ROOT.resolve() == ROOT, 'Wrong fresh remote installation root')
    require(platform.system() == 'Darwin' and platform.machine() == 'arm64', 'Apple Silicon macOS required')
    os.umask(0o077)
    started = time.monotonic()
    deadline = started+90
    def check(): require(time.monotonic() < deadline, 'Original parent deadline expired')
    previous = {}
    def interrupted(number, _): raise SystemExit(128+number)
    for number in (signal.SIGHUP, signal.SIGTERM, signal.SIGINT):
        previous[number] = signal.getsignal(number)
        signal.signal(number, interrupted)
    run, log, entered = None, None, False
    try:
        runs = ROOT/'runs'
        runs.mkdir(mode=0o700, exist_ok=True)
        require(runs.resolve() == runs and runs.stat().st_uid == os.geteuid()
                and runs.stat().st_mode & 0o077 == 0, 'Unsafe run parent')
        candidate = runs/(args.fixture+'-'+str(args.attempt))
        candidate.mkdir(mode=0o700)  # A used run directory is never overwritten.
        run = candidate
        pins = Pins(check)
        binding = verify_package(ROOT, args.package_sha256, pins, args.fixture)
        write_json(run/'input-binding.json', binding)
        values = read_command(['/usr/sbin/sysctl', '-n', 'hw.memsize', 'hw.model', 'kern.osversion',
                               'hw.pagesize', 'machdep.cpu.brand_string']).strip().splitlines()
        require(len(values) == 5 and values[0] == str(48*1024**3) and values[3] == '16384'
                and values[4] == 'Apple M4 Pro', 'This job requires the 48 GiB M4 Pro with 16 KiB pages')
        host = dict(platform=platform.platform(), machine=platform.machine(), physicalMemoryBytes=int(values[0]),
            hardwareModel=values[1], osBuild=values[2], pageSizeBytes=int(values[3]), cpuBrand=values[4],
            uid=os.geteuid(), expectedSSHTarget='developer@192.0.2.223')
        write_json(run/'host.json', host)
        log = os.fdopen(os.open(run/'resources.jsonl', os.O_WRONLY | os.O_CREAT | os.O_EXCL,
            0o600), 'wb', buffering=0)
        def publish_resource(row):
            PipeWorkers._write_all(log, canonical(row)+b'\n')
            require(row['pressureLevel'] == 1, 'Allocation cases require normal pressure level 1')
        gate = ResourceGate(publish_resource)
        gate('prelaunch'); check()
        before_processes = process_observation(deadline)
        write_json(run/'processes-preflight.json', before_processes)
        require(not before_processes['prohibited'], 'Known native/owner process is already live')
        before = journal_observation(device_directory())
        write_json(run/'journal-preflight.json', before)
        require_empty(before)
        # The observation lock has been closed. The launched native entry takes
        # the canonical gate itself before initializing/evaluating GPU arrays.
        pins.recheck()
        job = JOBS[args.fixture]
        spec = WorkerSpec((str(ROOT/'bundle'/job['product']), *job['runArguments']),
            {'PATH':'/usr/bin:/bin:/usr/sbin:/sbin', 'HOME':str(Path.home()), 'LANG':'C'}, 'solo', None)
        def postflight():
            after = journal_observation(device_directory())
            write_json(run/'journal-postflight.json', after)
            require_empty(after, before)
            processes = process_observation(deadline)
            write_json(run/'processes-postflight.json', processes)
            require(not processes['prohibited'], 'Known native/owner remains live after cleanup')
            return dict(journal=after, processObservation=processes)
        entered = True
        return serve(spec, run, started, gate, pins, postflight, args.fixture, host)
    except BaseException as error:
        if run is not None and not entered and not (run/'terminal.json').exists():
            write_json(run/'terminal.json', dict(schema='collective_allocation_native_observation_v1', fixture=args.fixture,
                status='failed', nativeLaunchAttempted=False, primaryFailure=cleanup_error_text(error)[0],
                modelTrunkExecutionObserved=False, registeredCheckpointExecution=False, bilateralVerification=False, journalMutationPerformed=False))
        raise
    finally:
        if log is not None: log.close()
        for number, handler in previous.items(): signal.signal(number, handler)


if __name__ == '__main__': raise SystemExit(main())
