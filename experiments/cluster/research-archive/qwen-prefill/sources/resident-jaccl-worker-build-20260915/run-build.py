"""Private isolated compiler invocation; model workloads are never launched."""

import datetime
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

root = Path(__file__).resolve().parent
experiment = root / 'workspace/experiments/cluster/inference'
records = root / 'records'
name = 'build-' + str(int(sys.argv[1]))
metallib = root.parent / 'peer24-short-parity-package-20260914/bundle/mlx.metallib'
original = root.parents[1] / 'd-inference/experiments/cluster/inference/Package.resolved'
pins = json.loads(original.read_bytes())['pins']
assert json.loads((experiment / 'Package.resolved').read_bytes())['pins'] == pins
env = os.environ.copy()
env['CLUSTER_METALLIB'] = str(metallib)
command = ['/bin/bash', 'build.sh']
start = time.monotonic()
with (records / (name + '.stdout.log')).open('xb') as out, (records / (name + '.stderr.log')).open('xb') as err:
    process = subprocess.Popen(command, cwd=experiment, env=env, stdout=out, stderr=err, start_new_session=True)
    with (records / (name + '.launch.json')).open('x') as handle:
        json.dump(dict(pid=process.pid, process_group=process.pid, command=command,
                       startedUTC=datetime.datetime.now(datetime.timezone.utc).isoformat()), handle)
    try:
        code = process.wait(timeout=600)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
        code = 124
def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()
record = dict(command=command, atUTC=datetime.datetime.now(datetime.timezone.utc).isoformat(),
              cwd=str(experiment), exit_code=code, elapsed_seconds=time.monotonic() - start,
              stdout_sha256=sha(records / (name + '.stdout.log')),
              stderr_sha256=sha(records / (name + '.stderr.log')), metallib_sha256=sha(metallib),
              model_executed=False, original_dependency_pins_preserved=
              json.loads((experiment / 'Package.resolved').read_bytes())['pins'] == pins)
if code == 0:
    record['binary_sha256'] = sha(experiment / '.build/arm64-apple-macosx/release/cluster-inference')
with (records / (name + '.json')).open('x') as handle:
    json.dump(record, handle, indent=2)
    handle.write('\n')
print(json.dumps(record))
if code:
    print((records / (name + '.stderr.log')).read_text()[-2500:])
    print((records / (name + '.stdout.log')).read_text()[-6500:])
