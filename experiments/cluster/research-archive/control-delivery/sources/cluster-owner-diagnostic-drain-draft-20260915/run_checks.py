"""Bounded local Foundation checks; never starts SSH, a model, or a remote owner."""
from pathlib import Path
import hashlib
import json
import os
import signal
import subprocess
import sys
import time

BASE = Path(__file__).resolve().parent


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def invoke(run, name, command, seconds):
    start = time.monotonic()
    failed = None
    with (run / (name + '.stdout')).open('xb') as out, (run / (name + '.stderr')).open('xb') as err:
        child = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=out, stderr=err, start_new_session=True)
        try:
            child.wait(timeout=seconds)
        except BaseException as error:
            failed = type(error).__name__
            # wait can itself reap before rethrowing KeyboardInterrupt. Never
            # signal a former group based on poll or a reaped child's old PID.
            if child.returncode is None:
                try:
                    os.killpg(child.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                child.wait()
            if not isinstance(error, subprocess.TimeoutExpired):
                raise
        finally:
            result = {'argv': command, 'ownedPID': child.pid, 'exitCode': child.returncode,
                      'failure': failed, 'elapsedSeconds': time.monotonic() - start}
            (run / (name + '.json')).write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({'phase': name, **result}), flush=True)
    return child.returncode if failed is None else 124


def main():
    side, attempt = sys.argv[1:]
    assert side in ('baseline', 'proposed') and attempt.isdecimal()
    run = BASE / ('checks-' + side + '-' + attempt)
    run.mkdir()
    paths = sorted((BASE / side).rglob('*.swift')) + sorted((BASE / 'Fixtures').glob('*.swift'))
    paths += [BASE / 'build_checks.sh', Path(__file__).resolve()]
    pins = [{'path': str(path.relative_to(BASE)), 'bytes': path.stat().st_size, 'sha256': sha(path)} for path in paths]
    (run / 'source-pins.json').write_text(json.dumps(pins, indent=2) + '\n')
    code = invoke(run, 'build', ['/bin/bash', str(BASE / 'build_checks.sh'), side, str(run / 'build')], 180)
    if code == 0:
        owned = run / 'owned'
        owned.mkdir()
        build = run / 'build'
        code = invoke(run, 'diagnostic-drain', [str(build / 'OwnerDiagnosticDrainTests'),
            str(build / 'LateDiagnosticOwner'), str(build / 'DiagnosticFailureWorker'), str(owned)], 35)
        if side == 'proposed' and code == 0:
            retirement = run / 'retirement-owned'
            retirement.mkdir()
            code = invoke(run, 'retirement-shutdown', [str(build / 'RetirementShutdownTests'), str(build / 'FakeOwner'),
                str(build / 'FakeClusterWorker'), str(retirement), 'corrected'], 90)
        if side == 'proposed' and code == 0:
            code = invoke(run, 'existing-ssh', [str(build / 'RemoteOwnerTests'), str(build / 'FakeOwner'),
                str(build / 'FakeClusterWorker')], 90)
    unchanged = all((BASE / pin['path']).stat().st_size == pin['bytes'] and sha(BASE / pin['path']) == pin['sha256'] for pin in pins)
    (run / 'execution.json').write_text(json.dumps({'side': side, 'exitCode': code,
        'sourcePinsUnchanged': unchanged, 'nativeModelOrNetworkExecution': False}, indent=2) + '\n')
    assert unchanged
    return code


if __name__ == '__main__':
    sys.exit(main())
