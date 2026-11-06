"""Retain each pure Foundation build/test attempt; never invokes SSH or a model."""
from pathlib import Path
import hashlib
import json
import subprocess
import sys
import time

base = Path(__file__).resolve().parent
side, attempt = sys.argv[1:]
assert side in ('baseline', 'proposed') and attempt.isdecimal()
run = base / ('checks-' + side + '-' + attempt)
run.mkdir()
sources = [p for folder in (base / side, base / 'Fixtures')
           for p in sorted(folder.rglob('*.swift'))]
sources += [base / 'build.sh', Path(__file__).resolve()]
pins = [{'path': str(p), 'bytes': p.stat().st_size,
         'sha256': hashlib.sha256(p.read_bytes()).hexdigest()} for p in sources]
(run / 'source-pins.json').write_text(json.dumps(pins, indent=2) + '\n')

def invoke(name, command, timeout):
    began = time.monotonic()
    with (run / (name + '.stdout')).open('xb') as out, (run / (name + '.stderr')).open('xb') as err:
        value = subprocess.run(command, stdin=subprocess.DEVNULL, stdout=out, stderr=err, timeout=timeout)
    result = {'command': command, 'exitCode': value.returncode, 'elapsedSeconds': time.monotonic() - began}
    (run / (name + '.json')).write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({'phase': name, **result}), flush=True)
    return value.returncode

build = run / 'build'
code = invoke('build', ['/bin/bash', str(base / 'build.sh'), side, str(build)], 180)
if code == 0:
    owned = run / 'owned'
    owned.mkdir()
    code = invoke('retirement-shutdown', [str(build / 'RetirementShutdownTests'), str(build / 'FakeOwner'),
        str(build / 'FakeClusterWorker'), str(owned), 'corrected' if side == 'proposed' else 'baseline'], 90)
    if side == 'proposed' and code == 0:
        code = invoke('existing-ssh', [str(build / 'RemoteOwnerTests'), str(build / 'FakeOwner'),
            str(build / 'FakeClusterWorker')], 90)
unchanged = all(Path(p['path']).stat().st_size == p['bytes'] and
                hashlib.sha256(Path(p['path']).read_bytes()).hexdigest() == p['sha256'] for p in pins)
(run / 'execution.json').write_text(json.dumps({'side': side, 'exitCode': code,
    'sourcePinsUnchanged': unchanged, 'nativeModelOrNetworkExecution': False}, indent=2) + '\n')
assert unchanged
sys.exit(code)
