"""Run the repository's actual Foundation-only checks and retain exact source pins."""
from pathlib import Path
import hashlib
import json
import os
import signal
import subprocess
import time

BASE = Path(__file__).resolve().parent
MAIN = BASE.parent.parent / 'd-inference'
PACKAGE = MAIN / 'libs/darkbloom-cluster'
OUTPUT = BASE / 'checks-2'


def pins():
    paths = []
    for module in ('Protocol', 'Process', 'Bootstrap', 'Remote'):
        paths.extend((PACKAGE / ('Sources/DarkbloomCluster' + module)).glob('*.swift'))
    paths.extend((PACKAGE / 'Tests/SSHChecks').glob('*.swift'))
    paths.extend(PACKAGE / relative for relative in (
        'Tests/ProcessChecks/FixtureIdentity.swift', 'Tests/ProcessChecks/FakeClusterWorker.swift',
        'Tests/SSHChecks/run.sh', 'Tools/ConfiguredOwner/main.swift'))
    return [{'path': str(path), 'bytes': path.stat().st_size,
             'sha256': hashlib.sha256(path.read_bytes()).hexdigest()} for path in sorted(paths)]


def main():
    OUTPUT.mkdir()
    before = pins()
    (OUTPUT / 'source-pins-before.json').write_text(json.dumps(before, indent=2) + '\n')
    argv = ['/bin/bash', 'libs/darkbloom-cluster/Tests/SSHChecks/run.sh']
    start = time.monotonic()
    failure = None
    with (OUTPUT / 'stdout').open('wb') as out, (OUTPUT / 'stderr').open('wb') as err:
        process = subprocess.Popen(argv, cwd=MAIN, stdout=out, stderr=err, start_new_session=True)
        print(json.dumps({'pid': process.pid, 'argv': argv, 'sourcePins': len(before)}), flush=True)
        try:
            process.wait(timeout=180)
        except BaseException as error:
            failure = type(error).__name__
            if process.returncode is None:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait()
    after = pins()
    (OUTPUT / 'source-pins-after.json').write_text(json.dumps(after, indent=2) + '\n')
    result = dict(argv=argv, exitCode=process.returncode, elapsedSeconds=time.monotonic() - start,
                  failure=failure, sourcePinsUnchanged=before == after, sourceCount=len(before),
                  compilerJobs=2, nativeModelOrNetworkExecuted=False,
                  stderrEmpty=(OUTPUT / 'stderr').stat().st_size == 0)
    (OUTPUT / 'execution.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result), flush=True)
    return 0 if process.returncode == 0 and failure is None and before == after else 1


if __name__ == '__main__':
    raise SystemExit(main())
