"""Run one correctness-only remote selected-load check and retain its evidence."""
from pathlib import Path
import hashlib
import json
import os
import shlex
import signal
import subprocess
import time

BASE = Path('/Users/developer/DarkbloomDev/cluster-research/qwen-mtp-selected-load-physical-20260915')
REMOTE = '/Users/developer/DarkbloomDev/qwen-mtp-selected-load-20260915'
SSH = ['ssh', '-T', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8']


def save(path, value):
    with path.open('x') as stream:
        stream.write(json.dumps(value, indent=2, sort_keys=True) + '\n')


def main():
    package = json.loads((BASE / 'package.json').read_text())
    assert package['host'] == 'darkbloom-48' and package['remoteRoot'] == REMOTE
    out = BASE / 'physical-1'; out.mkdir(mode=0o700)
    save(out / 'launcher-source.json', dict(path=__file__,
        sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest()))
    args = ['/usr/bin/python3', '-B', REMOTE + '/launcher/run_mtp_load.py',
            '--job', REMOTE + '/job-1.json', '--job-sha256', package['jobSHA256'],
            '--launcher-sha256', package['launcherSHA256']]
    command = SSH + ['darkbloom-48', shlex.join(args)]
    began = time.monotonic()
    record = dict(command=command, externalTimeoutSeconds=365, timedOut=False,
                  throughputMeasurementValid=False, nativeCleanupClaimedBySSHExit=False)
    with (out / 'ssh.stdout').open('xb') as stdout, (out / 'ssh.stderr').open('xb') as stderr:
        child = subprocess.Popen(command, stdout=stdout, stderr=stderr, start_new_session=True)
        save(out / 'launch.json', dict(command=command, localSSHPID=child.pid,
            startedUnix=time.time(), outerTimeoutSeconds=365))
        print('Remote 48 GB selected-load check launched; local SSH PID ' + str(child.pid), flush=True)
        try:
            record['sshExitCode'] = child.wait(timeout=365)
        except subprocess.TimeoutExpired:
            record['timedOut'] = True
            os.killpg(child.pid, signal.SIGTERM)
            try:
                record['sshExitCode'] = child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
                record['sshExitCode'] = child.wait()
    record['externalElapsedSeconds'] = time.monotonic() - began
    copy = ['scp', '-q', '-p', '-r', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8',
            'darkbloom-48:' + REMOTE + '/runs/physical-1', str(out / 'remote')]
    result = subprocess.run(copy, capture_output=True, text=True, timeout=180)
    record['evidenceCopy'] = dict(command=copy, exitCode=result.returncode,
        stdout=result.stdout, stderr=result.stderr)
    passed = False
    if result.returncode == 0 and (out / 'remote/terminal.json').exists():
        terminal = json.loads((out / 'remote/terminal.json').read_text())
        record['remoteTerminal'] = terminal
        checks = []
        for stream in terminal.get('streams', []):
            relative = Path(stream['path']).relative_to(REMOTE + '/runs/physical-1')
            path = out / 'remote' / relative
            actual = hashlib.sha256(path.read_bytes()).hexdigest()
            checks.append(dict(path=str(relative), matched=actual == stream['sha256']
                               and path.stat().st_size == stream['bytes']))
        record['retainedStreamChecks'] = checks
        passed = (record.get('sshExitCode') == 0 and not record['timedOut']
            and terminal.get('status') == 'completed' and terminal.get('recordsAccepted') == 2
            and terminal.get('nativeExitCodes') == [0] and bool(checks) and all(x['matched'] for x in checks)
            and all(terminal.get(key) is True for key in ['nativeLeaderReaped', 'ownedGroupFenceComplete',
                'outputComplete', 'journalEmptyAfterExit', 'sourceInputsUnchanged']))
    record['passed'] = passed
    save(out / 'execution.json', record)
    print(json.dumps(dict(passed=passed, sshExitCode=record.get('sshExitCode'),
        timedOut=record['timedOut'], externalElapsedSeconds=record['externalElapsedSeconds'],
        evidenceCopyExitCode=result.returncode)), flush=True)
    raise SystemExit(0 if passed else 1)


if __name__ == '__main__':
    main()
