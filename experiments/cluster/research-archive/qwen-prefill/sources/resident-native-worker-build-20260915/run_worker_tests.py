import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

root = Path(__file__).resolve().parent
run = root / ('tests-' + sys.argv[1])
run.mkdir()
package = root / 'workspace/libs/darkbloom-cluster'
argv = ['swift', 'test', '--package-path', str(package), '--jobs', '2',
        '--disable-index-store', '--disable-automatic-resolution', '--skip-update',
        '--filter', 'WorkerTests']
environment = dict(os.environ)
paths = [package / 'Package.swift'] + sorted((package / 'Sources').rglob('*.swift')) + sorted((package / 'Tests').rglob('*.swift'))
pins = [{'path': str(path.relative_to(package)), 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()} for path in paths]
result = {'argv': argv, 'modelOrGPUExecution': False, 'sourcePinsBefore': pins, 'fakeRuntimeAndRealLocalPipesOnly': True}
start = time.monotonic()
interrupted = None
with open(run / 'stdout', 'xb') as stdout, open(run / 'stderr', 'xb') as stderr:
    os.chmod(run / 'stdout', 0o600)
    os.chmod(run / 'stderr', 0o600)
    process = subprocess.Popen(argv, stdout=stdout, stderr=stderr, env=environment, start_new_session=True)
    print('Swift native worker fake-pipe tests PID', process.pid, 'records', run, flush=True)
    try:
        result['exitCode'] = process.wait(timeout=600)
    except BaseException as error:
        interrupted = error
        result['supervisionError'] = type(error).__name__
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        result['exitCode'] = process.wait(timeout=10)
    finally:
        result['elapsedSeconds'] = time.monotonic() - start
        stdout.flush(); stderr.flush()
        result['streams'] = {name: {'sha256': hashlib.sha256((run / name).read_bytes()).hexdigest(),
            'bytes': (run / name).stat().st_size} for name in ['stdout', 'stderr']}
        result['sourcePinsUnchanged'] = all(hashlib.sha256((package / p['path']).read_bytes()).hexdigest() == p['sha256'] for p in pins)
        (run / 'execution.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps({key: value for key, value in result.items() if key != 'sourcePinsBefore'}), flush=True)
if interrupted:
    raise interrupted
sys.exit(result['exitCode'])
