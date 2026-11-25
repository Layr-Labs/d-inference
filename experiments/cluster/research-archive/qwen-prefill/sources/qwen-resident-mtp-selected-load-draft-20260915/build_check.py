#!/usr/bin/env python3
"""Granted-slot native typecheck and parser checks only. Never invokes `load`."""
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent
PACKAGE = ROOT / 'workspace/libs/darkbloom-cluster-worker'
SCRATCH = PACKAGE / '.build-native-worker'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main(output):
    output.mkdir(mode=0o700, exist_ok=False)
    snapshot = json.loads((ROOT / 'build-source-snapshot.json').read_text())
    for row in snapshot['members']:
        assert sha(ROOT / 'workspace' / row['path']) == row['sha256'], row['path']
    receipt = {'sourceSnapshotSHA256': sha(ROOT / 'build-source-snapshot.json'),
               'scope': 'Native compilation and pure parser modes; no real payload/model/GPU execution', 'steps': []}

    def run(name, command, timeout):
        start = time.monotonic()
        with (output / (name + '.stdout')).open('wb') as out, (output / (name + '.stderr')).open('wb') as err:
            child = subprocess.Popen(command, stdout=out, stderr=err, start_new_session=True)
            try:
                code = child.wait(timeout=timeout)
            except BaseException:
                try:
                    os.killpg(child.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                finally:
                    child.wait()
                raise
        receipt['steps'].append({'name': name, 'command': command, 'exitCode': code,
                                 'elapsedSeconds': time.monotonic() - start,
                                 'stdoutSHA256': sha(output / (name + '.stdout')),
                                 'stderrSHA256': sha(output / (name + '.stderr'))})
        (output / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
        print(name, 'exit', code, 'seconds', round(time.monotonic() - start, 3), flush=True)
        if code:
            raise SystemExit(code)

    run('memory-before', ['/usr/bin/vm_stat'], 10)
    run('native-build', ['swift', 'build', '--package-path', str(PACKAGE), '--scratch-path', str(SCRATCH),
        '-c', 'release', '--jobs', '2', '--disable-automatic-resolution', '--skip-update',
        '--disable-build-manifest-caching', '--triple', 'arm64-apple-macosx26.2',
        '-Xcc', '-target', '-Xcc', 'arm64-apple-macosx26.2', '--product', 'MTPSelectedLoadCheck'], 900)
    binary = SCRATCH / 'arm64-apple-macosx/release/MTPSelectedLoadCheck'
    run('argument-check', [sys.executable, str(ROOT / 'Tests/check_arguments.py'), str(binary)], 90)
    run('build-version', ['/usr/bin/xcrun', 'vtool', '-show-build', str(binary)], 10)
    version = (output / 'build-version.stdout').read_text()
    assert version.count('LC_BUILD_VERSION') == 1 and 'platform MACOS' in version
    assert any(line.split() == ['minos', '26.2'] for line in version.splitlines())
    for row in snapshot['members']:
        assert sha(ROOT / 'workspace' / row['path']) == row['sha256'], row['path']
    receipt.update(status='passed', binarySHA256=sha(binary), unchangedSourceMembers=len(snapshot['members']))
    (output / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')


if __name__ == '__main__':
    main(ROOT / sys.argv[1])
