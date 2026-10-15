import hashlib
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

root = Path(__file__).resolve().parent
run = root / ('build-' + sys.argv[1])
run.mkdir()
package = root / 'workspace/libs/darkbloom-cluster'
argv = ['swift', 'build', '--package-path', str(package), '--target', 'DarkbloomClusterRuntime',
        '--jobs', '2', '--disable-index-store', '--disable-automatic-resolution', '--skip-update']
started = time.time()
result = {'argv': argv, 'startedUnix': started, 'modelOrGPUExecution': False, 'jobs': 2}
with open(run / 'stdout', 'xb') as stdout, open(run / 'stderr', 'xb') as stderr:
    os.chmod(run / 'stdout', 0o600); os.chmod(run / 'stderr', 0o600)
    process = subprocess.Popen(argv, stdout=stdout, stderr=stderr, start_new_session=True)
    print('Swift library build PID', process.pid, 'records', run, flush=True)
    try:
        result['exitCode'] = process.wait(timeout=900)
    except BaseException as error:
        result['supervisionError'] = type(error).__name__
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
        result['exitCode'] = process.returncode
        raise
    finally:
        result['elapsedSeconds'] = time.time() - started
        stdout.flush(); stderr.flush()
        result['streams'] = {name: {'sha256': hashlib.sha256((run / name).read_bytes()).hexdigest(),
                                    'bytes': (run / name).stat().st_size} for name in ['stdout', 'stderr']}
        (run / 'execution.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result), flush=True)
sys.exit(result['exitCode'])
