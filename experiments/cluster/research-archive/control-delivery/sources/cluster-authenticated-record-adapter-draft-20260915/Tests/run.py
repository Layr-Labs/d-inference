"""Run only after the root grants the one Foundation/CryptoKit compiler slot."""
import argparse
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import subprocess
import time

from owned_process import invoke_controller

BASE = Path(__file__).resolve().parent.parent


def verify_snapshot():
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
            # Exact shared helper prints one PID before its wait try block. Keep
            # this bounded observation off a potentially broken parent stdout.
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
            raise ValueError('Diagnostic output limit exceeded')
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
    binary = output / 'authenticated-record-adapter-check'
    sources = [str(BASE / name) for name in snapshot['swiftSources']]
    command = ['xcrun', 'swiftc', '-j', '2', '-swift-version', '6', '-warnings-as-errors',
               '-target', platform.machine() + '-apple-macos14.0', '-parse-as-library',
               '-module-cache-path', str(output / 'module-cache')] + sources + ['-o', str(binary)]
    compile_receipt = run_owned(command, output, 'compile', 60)
    verify_snapshot()
    fixture_receipt = run_owned([str(binary)], output, 'fixture', 10)
    verify_snapshot()
    lines = (output / 'fixture.stdout').read_text().splitlines()
    if len(lines) != 9 or not all(line.startswith('PASS ') for line in lines):
        raise ValueError('Incomplete authenticated-record adapter fixture result')
    if (output / 'compile.stderr').stat().st_size or (output / 'fixture.stderr').stat().st_size:
        raise ValueError('Unexpected compiler/fixture stderr')
    summary = {'compile': compile_receipt, 'fixture': fixture_receipt, 'passedGroups': 8,
               'privateSourcesUnchanged': True, 'mainChanged': False,
               'nativeModelConstructed': False, 'networkUsed': False,
               'membershipOrTransportQualified': False, 'nativeBridgeCompiled': False,
               'binarySHA256': hashlib.sha256(binary.read_bytes()).hexdigest()}
    (output / 'checks.json').write_text(json.dumps(summary, indent=2, sort_keys=True) + '\n')
    print(json.dumps({'passed': True, 'groups': 8, 'membershipOrTransportQualified': False}))


if __name__ == '__main__':
    main()
