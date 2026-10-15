"""Run only after root grants the Foundation compiler slot."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import signal
import subprocess
import time

BASE = Path(__file__).resolve().parent.parent


def verify_snapshot():
    snapshot = json.loads((BASE / 'compilation-snapshot.json').read_text())
    for item in snapshot['files']:
        raw = (BASE / item['path']).read_bytes()
        if len(raw) != item['sizeBytes'] or hashlib.sha256(raw).hexdigest() != item['sha256']:
            raise ValueError('Private compilation input changed: ' + item['path'])
    return snapshot


def kill_owned_group(child):
    try:
        os.killpg(child.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    child.wait(timeout=5)


def run_owned(argv, output, name, timeout):
    start = time.monotonic()
    record = {'argv': argv, 'timeoutSeconds': timeout, 'timedOut': False}
    child = None
    try:
        with (output / (name + '.stdout')).open('xb') as stdout, (output / (name + '.stderr')).open('xb') as stderr:
            child = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr,
                                     cwd=BASE, start_new_session=True)
            record['processID'] = child.pid
            try:
                record['exitCode'] = child.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                record['timedOut'] = True
                kill_owned_group(child)
                record['exitCode'] = child.returncode
            try:
                os.killpg(child.pid, 0)
            except ProcessLookupError:
                record['ownedGroupAbsent'] = True
            else:
                record['ownedGroupAbsent'] = False
                kill_owned_group(child)
    except BaseException:
        if child is not None:
            kill_owned_group(child)
        raise
    finally:
        record['elapsedSeconds'] = time.monotonic() - start
        (output / (name + '.json')).write_text(json.dumps(record, indent=2, sort_keys=True) + '\n')
    for suffix in ['stdout', 'stderr']:
        if (output / (name + '.' + suffix)).stat().st_size > 1_048_576:
            raise ValueError('Bounded diagnostic output exceeded')
    if record.get('exitCode') != 0 or record['timedOut'] or not record.get('ownedGroupAbsent'):
        raise ValueError(name + ' failed; raw receipts retained')
    return record


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(mode=0o700, parents=False, exist_ok=False)
    snapshot = verify_snapshot()
    (output / 'module-cache').mkdir(mode=0o700)
    binary = output / 'gemma-stage-plumbing-check'
    sources = [str(BASE / name) for name in snapshot['swiftSources']]
    command = ['xcrun', 'swiftc', '-j', '2', '-swift-version', '6', '-warnings-as-errors',
               '-target', platform.machine() + '-apple-macos14.0', '-parse-as-library',
               '-module-cache-path', str(output / 'module-cache')] + sources + ['-o', str(binary)]
    compile_receipt = run_owned(command, output, 'compile', 60)
    verify_snapshot()
    fixture_receipt = run_owned([str(binary), str(BASE / 'Inputs')], output, 'fixture', 10)
    verify_snapshot()
    result = json.loads((output / 'fixture.stdout').read_text())
    if (output / 'fixture.stderr').stat().st_size != 0 or result['runtimeExecutionAuthorized']:
        raise ValueError('Unexpected fixture stderr or execution claim')
    summary = {'compile': compile_receipt, 'fixture': fixture_receipt,
               'acceptedCount': result['acceptedCount'], 'refusedCount': result['refusedCount'],
               'privateSourcesUnchanged': True, 'nativeModelConstructed': False, 'payloadRead': False}
    (output / 'checks.json').write_text(json.dumps(summary, indent=2, sort_keys=True) + '\n')
    print(json.dumps({'passed': True, 'accepted': result['acceptedCount'], 'refused': result['refusedCount']}))


if __name__ == '__main__':
    main()
