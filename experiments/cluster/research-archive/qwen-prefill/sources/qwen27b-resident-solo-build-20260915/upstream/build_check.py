"""Explicit root-coordinated native compile OR model-free check; no model mode."""
from pathlib import Path
import argparse
import json
import os
import signal
import subprocess
import sys
import time
from prepare_build import DRAFT, BUILD, WORK, PACKAGE, digest, members, verify_source


def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('--phase', choices=('build', 'check'), required=True)
    parser.add_argument('--attempt', type=int, choices=range(1, 10), required=True)
    args = parser.parse_args()
    verify_source()
    pins = json.loads((BUILD / 'source-snapshot.json').read_bytes())
    assert members(WORK) == pins
    package = WORK / PACKAGE
    checkouts = package / '.build/checkouts'
    dependencies = members(checkouts)
    output = BUILD / (args.phase + '-' + str(args.attempt)); output.mkdir(mode=0o700)
    (output / 'dependency-source-pins.json').write_text(json.dumps(dependencies, indent=2, sort_keys=True) + '\n')
    binary = package / '.build/arm64-apple-macosx/release/cluster-inference'
    environment = dict(os.environ)
    if args.phase == 'build':
        command = ['swift', 'build', '-c', 'release', '--jobs', '2', '--disable-automatic-resolution',
            '--skip-update', '--disable-build-manifest-caching', '--product', 'cluster-inference',
            '--triple', 'arm64-apple-macosx26.2', '-Xcc', '-target', '-Xcc', 'arm64-apple-macosx26.2']
        timeout = 900
    else:
        command = [str(binary), '--mode', 'qwen-resident-solo-generation-check']; timeout = 60
        environment['DARKBLOOM_RETAINED_PROFILE_FIXTURE'] = str(DRAFT / 'Tests/retained-inputs.json')
    began = time.monotonic(); interrupted = None
    with (output / 'stdout').open('xb') as stdout, (output / 'stderr').open('xb') as stderr:
        child = subprocess.Popen(command, cwd=package, env=environment,
            stdout=stdout, stderr=stderr, start_new_session=True)
        (output / 'started.json').write_text(json.dumps({'pid': child.pid, 'argv': command, 'timeoutSeconds': timeout}) + '\n')
        print(json.dumps({'phase': args.phase, 'pid': child.pid, 'output': str(output)}), flush=True)
        try:
            child.wait(timeout=timeout)
        except BaseException as error:
            interrupted = type(error).__name__
            # wait may already reap on KeyboardInterrupt. Never signal a reused
            # group after a known reaped child, and never poll before this guard.
            if child.returncode is None:
                os.killpg(child.pid, signal.SIGTERM)
                try: child.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGKILL); child.wait(timeout=10)
    unchanged = members(WORK) == pins and members(checkouts) == dependencies
    receipt = {'schema': 'resident_solo_build_or_check_v1', 'phase': args.phase, 'argv': command,
        'pid': child.pid, 'exitCode': child.returncode, 'elapsedSeconds': time.monotonic() - began,
        'interruption': interrupted, 'sourcePinsUnchanged': unchanged, 'sourceCount': len(pins),
        'dependencySourceCount': len(dependencies), 'sourceSnapshotSHA256': digest(BUILD / 'source-snapshot.json'),
        'stdoutSHA256': digest(output / 'stdout'), 'stderrSHA256': digest(output / 'stderr'),
        'modelExecuted': False, 'remoteOperations': False, 'mainModified': False}
    if child.returncode == 0:
        receipt['binarySHA256'] = digest(binary)
        if args.phase == 'check': receipt['result'] = json.loads((output / 'stdout').read_bytes())
    (output / 'execution.json').write_text(json.dumps(receipt, indent=2, sort_keys=True) + '\n')
    print(json.dumps(receipt, sort_keys=True), flush=True)
    sys.exit(0 if child.returncode == 0 and unchanged and interrupted is None else 1)


if __name__ == '__main__':
    main()
