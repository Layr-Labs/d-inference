"""Run only after root grants the Foundation compiler slot."""
import argparse
import contextlib
import io
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import time

from owned_process import invoke_controller

CORRECTION = Path(__file__).resolve().parent
BASE = CORRECTION.parent / 'gemma4-stage-plumbing-draft-20260915'


def verify_snapshot():
    for item in json.loads((CORRECTION / 'runner-inputs.json').read_text())['files']:
        raw = (CORRECTION / item['path']).read_bytes()
        if len(raw) != item['sizeBytes'] or hashlib.sha256(raw).hexdigest() != item['sha256']:
            raise ValueError('Corrected runner source changed: ' + item['path'])
    snapshot = json.loads((BASE / 'compilation-snapshot.json').read_text())
    for item in snapshot['files']:
        raw = (BASE / item['path']).read_bytes()
        if len(raw) != item['sizeBytes'] or hashlib.sha256(raw).hexdigest() != item['sha256']:
            raise ValueError('Private compilation input changed: ' + item['path'])
    return snapshot


def run_owned(argv, output, name, timeout):
    start = time.monotonic()
    record = {'argv': argv, 'timeoutSeconds': timeout, 'timedOut': False}
    try:
        with (output / (name + '.stdout')).open('xb') as stdout, (output / (name + '.stderr')).open('xb') as stderr:
            # The exact shared helper prints its PID before its wait try block.
            # Keep that bounded line in memory, never a potentially broken output pipe.
            with contextlib.redirect_stdout(io.StringIO()) as observation:
                invoke_controller(argv, stdout, stderr, record, timeout=timeout)
            record['launchObservation'] = observation.getvalue()
    except BaseException as error:
        record['timedOut'] = isinstance(error, subprocess.TimeoutExpired)
        raise
    finally:
        record['elapsedSeconds'] = time.monotonic() - start
        (output / (name + '.json')).write_text(json.dumps(record, indent=2, sort_keys=True) + '\n')
    for suffix in ['stdout', 'stderr']:
        if (output / (name + '.' + suffix)).stat().st_size > 1_048_576:
            raise ValueError('Bounded diagnostic output exceeded')
    if record.get('exitCode') != 0 or record['timedOut'] or not record.get('reaped') or not record.get('groupAbsent'):
        raise ValueError(name + ' failed; raw receipts retained')
    return record


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(mode=0o700, parents=False, exist_ok=False)
    snapshot = verify_snapshot()
    os.chdir(BASE)
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
