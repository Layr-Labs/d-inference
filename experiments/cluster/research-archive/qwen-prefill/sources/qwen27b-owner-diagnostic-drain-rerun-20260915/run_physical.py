"""One correctness request over actual owner SSH; retains every failure/cleanup observation."""
from pathlib import Path
import hashlib
import json
import os
import queue
import select
import shlex
import subprocess
import threading
import time
from lease_source import LEASE
from parent_settings import SSH
from probe_postflight import postflight
from parent_cleanup import invoke_controller, observe_retirement

BASE = Path(__file__).resolve().parent
ROOT = BASE.parent
REMOTE = '/Users/developer/DarkbloomDev/qwen27b-owner-validation-20260915'
OUTPUT = BASE / 'physical-1'

CONTROLLER = ROOT / 'cluster-owner-diagnostic-drain-draft-20260915/local-bundle/owner-controller'


class Monitor:
    def __init__(self, host, rank):
        self.first = queue.Queue(maxsize=1)
        self.errors = []
        self.out = (OUTPUT / f'resources-{rank}.jsonl').open('xb')
        self.err = (OUTPUT / f'resources-{rank}.stderr').open('xb')
        self.process = subprocess.Popen(SSH + [host, shlex.join(['/usr/bin/python3', '-B', REMOTE + '/monitor.py'])],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.err)
        self.thread = threading.Thread(target=self.read, daemon=True)
        self.thread.start()

    def read(self):
        try:
            count = 0
            while True:
                line = self.process.stdout.readline(65537)
                if not line:
                    break
                self.out.write(line); self.out.flush()
                if len(line) > 65536 or not line.endswith(b'\n') or count >= 1400:
                    raise RuntimeError('Monitor output exceeded bound')
                record = json.loads(line)
                if count == 0:
                    self.first.put(record)
                count += 1
        except Exception as error:
            self.errors.append(type(error).__name__ + ': ' + str(error))
        finally:
            if self.first.empty():
                self.first.put({'admissible': False, 'error': 'Monitor ended before first sample'})

    def stop(self):
        try:
            self.process.stdin.write(b'stop\n'); self.process.stdin.flush()
        except (BrokenPipeError, OSError):
            pass
        try:
            self.process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            self.errors.append('Monitor SSH exceeded shutdown bound')
            self.process.kill(); self.process.wait(timeout=5)
        self.thread.join(timeout=5)
        if self.thread.is_alive():
            self.errors.append('Monitor reader did not join')
        else:
            self.out.close()
        self.err.close()
        return {'exitCode': self.process.returncode, 'errors': self.errors}


def main():
    OUTPUT.mkdir(exist_ok=False)
    os.chmod(OUTPUT, 0o700)
    pins = json.loads((BASE / 'run-pins.json').read_text())
    for entry in pins['files']:
        if hashlib.sha256(Path(entry['path']).read_bytes()).hexdigest() != entry['sha256']:
            raise RuntimeError('Pinned input changed: ' + entry['path'])
    record = {'schema': 'native_owner_physical_execution_v1', 'performanceQualified': False,
        'externalTTFTQualified': False, 'numericalQualified': False, 'startedUnix': time.time()}
    started = time.monotonic()
    monitors = []
    lease = None
    password = ''
    controller_started = None
    try:
        for rank, host in enumerate(['darkbloom-24', 'darkbloom-48']):
            monitor = Monitor(host, rank); monitors.append(monitor)
            sample = monitor.first.get(timeout=15)
            if sample.get('admissible') is not True:
                raise RuntimeError('Initial resource sample refused rank ' + str(rank))
        rows = [[cell.strip().strip('`') for cell in line.strip().strip('|').split('|')]
            for line in (ROOT.parent / 'machines/CREDENTIALS.private.md').read_text().splitlines() if line.startswith('|')]
        password = rows[2][[cell.lower() for cell in rows[0]].index('password')]
        connection = subprocess.run(SSH + ['darkbloom-48', '/usr/bin/printenv', 'SSH_CONNECTION'],
            capture_output=True, text=True, check=True, timeout=10)
        fields = connection.stdout.split()
        if len(fields) != 4 or ':' in fields[0]:
            raise RuntimeError('Management connection shape differs')
        with (OUTPUT / 'lease.stderr').open('xb') as err:
            os.fchmod(err.fileno(), 0o600)
            lease = subprocess.Popen(SSH + ['darkbloom-48', shlex.join(['/usr/bin/sudo', '-k', '-S', '-p', '',
                '/usr/bin/python3', '-c', LEASE, fields[0]])], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=err, bufsize=0)
        lease.stdin.write((password + '\n').encode()); lease.stdin.flush()
        line = bytearray(); until = time.monotonic() + 15
        while b'\n' not in line:
            if time.monotonic() >= until:
                raise RuntimeError('Alias readiness deadline exceeded')
            if not select.select([lease.stdout], [], [], 1)[0]:
                continue
            block = os.read(lease.stdout.fileno(), 1)
            if not block or len(line) > 65536:
                raise RuntimeError('Alias readiness stream ended or exceeded bound')
            line.extend(block)
        record['aliasReady'] = json.loads(line)
        if record['aliasReady'].get('state') != 'ready':
            raise RuntimeError('Alias not admitted')
        controller_started = time.monotonic()
        command = [str(CONTROLLER), str(BASE / 'configuration/controller.json')]
        record['controllerInvocation'] = command
        with (OUTPUT / 'controller.stdout.jsonl').open('xb') as out, (OUTPUT / 'controller.stderr').open('xb') as err:
            record['localController'] = {}
            invoke_controller(command, out, err, record['localController'])
        record['controllerExitCode'] = record['localController']['exitCode']
    except BaseException as error:
        record['error'] = type(error).__name__ + ': ' + str(error)
    finally:
        # Reuse the current HTTP postflight ordering. Keep the alias while any
        # owner/native may remain, including after timeout killed the controller.
        origin = controller_started if controller_started is not None else started
        try:
            observations = []
            def collect(rank, timeout):
                return postflight(['darkbloom-24', 'darkbloom-48'][rank], timeout=timeout)
            cleanup = observe_retirement(origin + 420, collect, observations.append)
            # Publication follows the bounded observation so a disk failure
            # cannot skip the wait and release the alias around a live child.
            record['remoteCleanup'] = cleanup
            with (OUTPUT / 'postflight-observations.jsonl').open('xb') as observed:
                for value in observations:
                    observed.write((json.dumps(value, sort_keys=True) + '\n').encode())
            record['nativeProcessesAbsent'] = cleanup['nativeProcessesAbsent']
            record['journalsEmpty'] = cleanup['journalsEmpty']
            if cleanup.get('interrupted'):
                record.setdefault('error', cleanup['interrupted'])
        except BaseException as error:
            record['remoteCleanupError'] = type(error).__name__ + ': ' + str(error)
            record['nativeProcessesAbsent'] = False; record['journalsEmpty'] = False
        if record.get('localController'):
            record['controllerExitCode'] = record['localController'].get('exitCode')
        record['aliasReleaseAfterControllerSeconds'] = time.monotonic() - origin
        if lease:
            try:
                lease.stdin.write(b'release\n'); lease.stdin.flush()
            except (BrokenPipeError, OSError):
                pass
            try:
                tail, _ = lease.communicate(timeout=40)
                (OUTPUT / 'lease.stdout.tail.jsonl').write_bytes(tail)
                record['leaseExitCode'] = lease.returncode
                record['leaseFinal'] = [json.loads(line) for line in tail.splitlines() if line.strip()]
            except BaseException as error:
                record['cleanupUnconfirmed'] = True
                record['cleanupObservationError'] = type(error).__name__ + ': ' + str(error)
                try:
                    lease.terminate(); lease.wait(timeout=5)
                except BaseException as failure:
                    record['localLeaseTerminationError'] = type(failure).__name__ + ': ' + str(failure)
        record['monitors'] = [monitor.stop() for monitor in monitors]
    record['elapsedSeconds'] = time.monotonic() - started
    record['pinsUnchanged'] = all(hashlib.sha256(Path(x['path']).read_bytes()).hexdigest() == x['sha256'] for x in pins['files'])
    final = record.get('leaseFinal', [])
    record['runCompletedAndAliasRestored'] = (record.get('controllerExitCode') == 0 and 'error' not in record
        and record.get('leaseExitCode') == 0 and len(final) == 1 and final[0].get('restored') is True
        and record.get('nativeProcessesAbsent') is True and record.get('journalsEmpty') is True
        and record.get('localController', {}).get('reaped') is True
        and record.get('localController', {}).get('groupAbsent') is True
        and record['pinsUnchanged'] and all(m['exitCode'] == 0 and not m['errors'] for m in record['monitors']))
    record['outputFiles'] = [{'path': p.name, 'bytes': p.stat().st_size, 'sha256': hashlib.sha256(p.read_bytes()).hexdigest()}
        for p in sorted(OUTPUT.iterdir()) if p.is_file()]
    raw = json.dumps(record, indent=2) + '\n'
    if password:
        raw = raw.replace(password, '[REDACTED]')
    (OUTPUT / 'execution.json').write_text(raw)
    print(json.dumps({k: record.get(k) for k in ['controllerExitCode', 'error', 'leaseExitCode', 'runCompletedAndAliasRestored', 'elapsedSeconds']}))
    raise SystemExit(0 if record['runCompletedAndAliasRestored'] else 1)


if __name__ == '__main__':
    main()
