"""Exercise supervisor child ownership with a ready-signalled fake product."""
from pathlib import Path
import hashlib
import json
import os
import subprocess
import sys
import time

BASE = Path(__file__).resolve().parent
SOURCE = BASE / 'installed_product_supervisor_20260915.py'
OUTPUT = BASE / 'installed-product-supervisor-checks2-20260915'


def wait_ready(marker, process):
    until = time.monotonic() + 5
    while time.monotonic() < until:
        if marker.exists():
            return int(marker.read_text())
        if process.poll() is not None:
            raise AssertionError('Supervisor exited before fake child readiness')
        time.sleep(0.01)
    raise AssertionError('Fake child did not become ready')


def is_alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


def run_case(name, control=None, broken_output=False):
    folder = OUTPUT / name
    product = folder / 'product'
    product.mkdir(parents=True, mode=0o700)
    marker = product / 'child-ready'
    fake = product / 'darkbloom'
    fake.write_text(
        '#!/usr/bin/python3\n'
        'from pathlib import Path\nimport os, signal, sys, time\n'
        'signal.signal(signal.SIGTERM, lambda *args: sys.exit(0))\n'
        f'Path({str(marker)!r}).write_text(str(os.getpid()))\n'
        'while True: time.sleep(0.01)\n'
    )
    fake.chmod(0o700)
    source = SOURCE.read_text()
    old = "root = Path('/Users/developer/DarkbloomDev/installed-distributed-runtime-20260915')"
    assert source.count(old) == 1
    adapted = folder / 'supervisor.py'
    adapted.write_text(source.replace(old, f'root = Path({str(product)!r})'))
    write_fd = None
    if broken_output:
        read_fd, write_fd = os.pipe()
        os.close(read_fd)
    command = [sys.executable, '-B', str(adapted), str(product / 'qualification' / 'run')]
    with (folder / 'stderr').open('xb') as stderr:
        process = subprocess.Popen(command, stdin=subprocess.PIPE,
            stdout=write_fd if broken_output else subprocess.PIPE, stderr=stderr)
        if write_fd is not None:
            os.close(write_fd)
        try:
            pid = None
            if not broken_output:
                started = json.loads(process.stdout.readline())
                assert started['state'] == 'started'
                pid = wait_ready(marker, process)
                assert pid == started['pid']
                process.stdin.write(control)
                process.stdin.flush()
            # In the partial-input case stdin deliberately remains open here.
            process.wait(timeout=5)
            out, _ = process.communicate(timeout=1)
        finally:
            if process.poll() is None:
                process.stdin.close()
                process.wait(timeout=28)
    if pid is None and marker.exists():
        pid = int(marker.read_text())
    assert pid is None or not is_alive(pid), 'Fake child leaked'
    active = subprocess.check_output(['ps', '-axo', 'pid=,command='], text=True)
    assert not any(str(fake) in line for line in active.splitlines()), 'Fake child still in process table'
    if not broken_output:
        receipt = json.loads((product / 'qualification/run/supervisor.json').read_text())
        assert process.returncode == 0 and receipt['exitCode'] == 0
        assert receipt['forcedKill'] is False
        assert receipt['stopReason'] == ('requested-stop' if control == b'stop\n' else 'control-input-or-eof')
    else:
        assert process.returncode != 0
    (folder / 'stdout').write_bytes(out or b'')
    return {'case': name, 'passed': True, 'supervisorExitCode': process.returncode,
            'childAbsent': True}


def main():
    OUTPUT.mkdir(mode=0o700)
    started = time.monotonic()
    results = [run_case('normal', b'stop\n'), run_case('partial', b's'),
               run_case('broken-publication', broken_output=True)]
    receipt = {'schema': 'installed_product_supervisor_checks_v1',
               'sourceSHA256': hashlib.sha256(SOURCE.read_bytes()).hexdigest(),
               'elapsedSeconds': time.monotonic() - started, 'results': results}
    (OUTPUT / 'checks.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps(receipt))


if __name__ == '__main__':
    main()
