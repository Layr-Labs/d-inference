"""Private source snapshot + offline bounded Go checks; requires root compiler grant."""
import argparse
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import resource
import time

from owned_process import invoke_controller

BASE = Path(__file__).resolve().parent.parent
GO = Path('/Users/developer/.local/share/mise/installs/go/1.25.0/bin/go')


def read_bound(path, row):
    raw = path.read_bytes()
    if len(raw) != row['sizeBytes'] or hashlib.sha256(raw).hexdigest() != row['sha256']:
        raise ValueError('Source identity changed: ' + row['path'])
    return raw


def verify(repo, workspace=None):
    snapshot = json.loads((BASE / 'compilation-snapshot.json').read_text())
    for row in snapshot['files']:
        source = (BASE / 'proposed' if row['source'] == 'proposed' else repo) / row['path']
        read_bound(source, row)
        if workspace is not None:
            read_bound(workspace / row['path'], row)
    for row in json.loads((BASE / 'base-pins.json').read_text()):
        if hashlib.sha256((repo / row['path']).read_bytes()).hexdigest() != row['sha256']:
            raise ValueError('MAIN preimage changed: ' + row['path'])
    return snapshot


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--repo', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--all-registry', action='store_true')
    args = parser.parse_args()
    repo, output = args.repo.resolve(), args.output.resolve()
    snapshot = verify(repo)
    output.mkdir(mode=0o700, parents=False, exist_ok=False)
    workspace = output / 'workspace'
    workspace.mkdir(mode=0o700)
    for row in snapshot['files']:
        source = (BASE / 'proposed' if row['source'] == 'proposed' else repo) / row['path']
        destination = workspace / row['path']
        destination.parent.mkdir(parents=True, exist_ok=True)
        with destination.open('xb') as stream:
            stream.write(read_bound(source, row))
    verify(repo, workspace)
    (output / 'source-snapshot.json').write_text(json.dumps(snapshot, indent=2) + '\n')
    # No dependency installation, external coordinator or toolchain download.
    # Existing Go caches are reused; root owns compiler/cache concurrency.
    os.environ.update(GOMAXPROCS='2', GOPROXY='off', GOSUMDB='off',
                      GOTOOLCHAIN='local', GOWORK='off', GOFLAGS='-mod=readonly')
    os.chdir(workspace)
    command = [str(GO), 'test', '-json', '-race', '-p', '2', '-count=1', '-timeout=120s']
    if not args.all_registry:
        command += ['-run', '^TestVerifiedPair']
    command += ['./coordinator/registry']
    receipt = {'argv': command, 'sourceFiles': len(snapshot['files']), 'compilerParallelism': 2,
               'goBinarySHA256': hashlib.sha256(GO.read_bytes()).hexdigest()}
    began = time.monotonic()
    old_limit = resource.getrlimit(resource.RLIMIT_FSIZE)
    # Go also writes object archives/test binaries: a 16 MiB process-wide file
    # cap would corrupt a legitimate race build. Hard cap each file at 512 MiB;
    # refuse diagnostic files above 16 MiB before loading/parsing them.
    bound = 512 * 1024 * 1024
    resource.setrlimit(resource.RLIMIT_FSIZE, (bound, old_limit[1]))
    try:
        with (output / 'tests.stdout').open('xb') as stdout, (output / 'tests.stderr').open('xb') as stderr:
            with contextlib.redirect_stdout(io.StringIO()) as launch:
                invoke_controller(command, stdout, stderr, receipt, timeout=300)
            receipt['launchObservation'] = launch.getvalue()
    finally:
        resource.setrlimit(resource.RLIMIT_FSIZE, old_limit)
        receipt['elapsedSeconds'] = time.monotonic() - began
        (output / 'execution.json').write_text(json.dumps(receipt, indent=2, sort_keys=True) + '\n')
    verify(repo, workspace)
    if any((output / name).stat().st_size > 16 * 1024 * 1024 for name in ['tests.stdout', 'tests.stderr']):
        raise ValueError('Diagnostic output exceeded parser bound; raw files retained')
    events = [json.loads(line) for line in (output / 'tests.stdout').read_text().splitlines() if line]
    passed = {e['Test'] for e in events if e.get('Action') == 'pass' and 'Test' in e and '/' not in e['Test']}
    new_tests = {name for name in passed if name.startswith('TestVerifiedPair')}
    complete = any(e.get('Action') == 'pass' and e.get('Package') == 'github.com/eigeninference/d-inference/coordinator/registry' and 'Test' not in e for e in events)
    if receipt.get('exitCode') != 0 or not receipt.get('reaped') or not receipt.get('groupAbsent') or not complete or len(new_tests) != 15:
        raise ValueError('Go checks failed or incomplete; source and raw receipts retained')
    result = {'passed': True, 'newTestMethods': len(new_tests), 'totalTestMethods': len(passed),
              'raceDetectorEnabled': True, 'sourcePinsUnchanged': True, 'mainEdited': False,
              'externalCoordinatorUsed': False, 'nativeOrKeyEstablishmentQualified': False}
    (output / 'checks.json').write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')
    print(json.dumps(result, sort_keys=True))


if __name__ == '__main__':
    main()
