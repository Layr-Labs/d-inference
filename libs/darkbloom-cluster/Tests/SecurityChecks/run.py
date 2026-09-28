"""Compile and run the actual CPU record implementation without MLX or a peer."""
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

HERE = Path(__file__).resolve().parent
RUNTIME = HERE.parent.parent / 'Sources/DarkbloomClusterSecurity'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def snapshot(paths):
    result = {}
    for path in paths:
        if path.is_symlink() or not path.is_file():
            raise ValueError('Expected regular source/fixture: ' + str(path))
        result[str(path)] = digest(path)
    return result


def run_owned(argv, output, name, timeout):
    record = {'argv': argv, 'timeoutSeconds': timeout, 'timedOut': False}
    started = time.monotonic()
    try:
        with (output / (name + '.stdout')).open('xb') as stdout, (output / (name + '.stderr')).open('xb') as stderr:
            # The shared helper prints its PID before entering its wait guard.
            # A closed console pipe must not strand the child at that print.
            with contextlib.redirect_stdout(io.StringIO()) as observation:
                invoke_controller(argv, stdout, stderr, record, timeout=timeout)
            record['launchObservation'] = observation.getvalue()
    except BaseException as error:
        record['timedOut'] = isinstance(error, subprocess.TimeoutExpired)
        raise
    finally:
        record['elapsedSeconds'] = time.monotonic() - started
        (output / (name + '.json')).write_text(json.dumps(record, indent=2, sort_keys=True) + '\n')
    for suffix in ('stdout', 'stderr'):
        if (output / (name + '.' + suffix)).stat().st_size > 1_048_576:
            raise ValueError('Diagnostic output exceeds the check limit')
    if record.get('exitCode') != 0 or not record.get('reaped') or not record.get('groupAbsent'):
        raise ValueError(name + ' failed; inspect the retained process receipt and stderr')
    if (output / (name + '.stderr')).stat().st_size:
        raise ValueError(name + ' wrote unexpected stderr')
    return record


def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('--output', type=Path, required=True, help='New directory for binaries, logs and receipts')
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(mode=0o700, parents=False, exist_ok=False)
    runtime = sorted(RUNTIME.glob('*.swift'))
    if len(runtime) != 8:
        raise ValueError('Update the CPU check source closure when changing the record module')
    groups = [('codec', sorted((HERE / 'Codec').glob('*.swift')), [str(HERE / 'Codec/vectors.json')]),
              ('adapter', sorted((HERE / 'Adapter').glob('*.swift')), [])]
    paths = runtime + [path for _, sources, _ in groups for path in sources]
    paths += [HERE / 'Codec/vectors.json', HERE / 'owned_process.py', HERE / 'run.py']
    before = snapshot(paths)
    (output / 'source-snapshot.json').write_text(json.dumps(before, indent=2, sort_keys=True) + '\n')
    (output / 'module-cache').mkdir(mode=0o700)
    receipts = []
    try:
        for name, sources, arguments in groups:
            binary = output / (name + '-check')
            command = ['xcrun', 'swiftc', '-j', '2', '-swift-version', '6', '-warnings-as-errors',
                       '-target', platform.machine() + '-apple-macos14.0', '-parse-as-library',
                       '-module-cache-path', str(output / 'module-cache')]
            receipts.append(run_owned(command + [str(path) for path in runtime + sources]
                                      + ['-o', str(binary)], output, name + '-compile', 60))
            if snapshot(paths) != before:
                raise ValueError('Sources changed while compiling')
            receipts.append(run_owned([str(binary)] + arguments, output, name + '-fixture', 10))
            lines = (output / (name + '-fixture.stdout')).read_text().splitlines()
            if len(lines) != 9 or not all(line.startswith('PASS ') for line in lines):
                raise ValueError('Incomplete ' + name + ' fixture output')
    finally:
        unchanged = snapshot(paths) == before
        (output / 'source-recheck.json').write_text(json.dumps({'unchanged': unchanged}) + '\n')
        if not unchanged:
            raise ValueError('Sources changed during CPU checks')
    (output / 'checks.json').write_text(json.dumps({'passed': True, 'passedGroups': 16,
        'steps': receipts, 'sourceUnchanged': True, 'nativeBridgeCompiled': False,
        'modelExecuted': False, 'networkUsed': False}, indent=2, sort_keys=True) + '\n')
    print('PASS 16 record codec/adapter CPU groups; no native bridge or network qualification')


if __name__ == '__main__':
    os.umask(0o077)
    main()
