"""Compile the reviewed selected-read candidate in its isolated workspace."""
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import time

root = Path(__file__).resolve().parent
build = root / 'resident-aligned-read-build-20260915'
workspace = build / 'workspace'
records = build / 'records'


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


snapshot = records / 'source-snapshot.json'
source = json.loads(snapshot.read_bytes())
for item in source['files']:
    assert digest(workspace / item['path']) == item['sha256'], item['path']
assert (records / 'reviewed-overlay.json').is_file()
raw = subprocess.run(['/usr/bin/vm_stat'], check=True, capture_output=True, text=True).stdout
page = int(re.search(r'page size of (\d+) bytes', raw).group(1))
free_pages = int(re.search(r'Pages free:\s*(\d+)', raw).group(1))
speculative = int(re.search(r'Pages speculative:\s*(\d+)', raw).group(1))
free = max(0, free_pages - speculative) * page
assert free >= 6 * 1024**3, 'Local compilation actual-free floor'
env = dict(os.environ, CLUSTER_METALLIB=str(root.parent / 'd-inference/provider-swift/.build/debug/mlx.metallib'))
started = time.monotonic()
record = dict(command=['/bin/bash', 'build.sh'],
              startedAtUTC=datetime.datetime.now(datetime.timezone.utc).isoformat(),
              sourceSnapshotSHA256=digest(snapshot), initialVMStat=raw)
with (records / 'build-1.stdout.log').open('xb') as stdout, (records / 'build-1.stderr.log').open('xb') as stderr:
    process = subprocess.Popen(record['command'], cwd=workspace / 'experiments/cluster/inference',
                               stdout=stdout, stderr=stderr, env=env, start_new_session=True)
    try:
        record['exitCode'] = process.wait(timeout=700)
    except BaseException as error:
        record['failure'] = type(error).__name__ + ': ' + str(error)
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        record['exitCode'] = process.wait(timeout=15)
record['elapsedSeconds'] = time.monotonic() - started
record['logs'] = {name: dict(bytes=(records / name).stat().st_size, sha256=digest(records / name))
                  for name in ['build-1.stdout.log', 'build-1.stderr.log']}
if record['exitCode'] == 0:
    record['nativeSHA256'] = digest(workspace / 'experiments/cluster/inference/.build/arm64-apple-macosx/release/cluster-inference')
    for item in source['files']:
        assert digest(workspace / item['path']) == item['sha256'], item['path']
(records / 'build-1.json').write_text(json.dumps(record, indent=2) + '\n')
print(json.dumps(record), flush=True)
assert record['exitCode'] == 0 and 'failure' not in record
