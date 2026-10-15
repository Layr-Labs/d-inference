"""Standalone Foundation-only fixture; never imports or launches MLX."""
from pathlib import Path
import hashlib
import json
import subprocess
import time

root = Path(__file__).resolve().parent
listing = json.loads((root / 'foundation-source-list.json').read_text())

def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def verify():
    for item in listing['sources'] + [listing['stdin']]:
        assert digest(item['path']) == item['sha256'], item['path']

verify()
out = root / 'cpu-v1'
out.mkdir(exist_ok=False)
binary = out / 'reference-check'
cmd = ['xcrun', 'swiftc', '-swift-version', '6', '-warnings-as-errors',
       '-module-cache-path', str(out / 'ModuleCache')]
cmd += [item['path'] for item in listing['sources']] + ['-o', str(binary)]

def run(name, command, data=None):
    start = time.monotonic()
    with (out / (name + '.stdout')).open('wb') as stdout, (out / (name + '.stderr')).open('wb') as stderr:
        result = subprocess.run(command, input=data, stdout=stdout, stderr=stderr, timeout=60, check=False)
    return {'argv': command, 'exitCode': result.returncode, 'elapsedSeconds': time.monotonic() - start,
            'stdoutSHA256': digest(out / (name + '.stdout')), 'stderrSHA256': digest(out / (name + '.stderr'))}

record = {'compile': run('compile', cmd), 'modelForwardExecuted': False,
          'sourceListSHA256': digest(root / 'foundation-source-list.json')}
if record['compile']['exitCode'] == 0:
    record['test'] = run('test', [str(binary)], Path(listing['stdin']['path']).read_bytes())
verify()
record['sourceAndInputPinsUnchanged'] = True
(out / 'execution.json').write_text(json.dumps(record, indent=2) + '\n')
print(json.dumps(record, sort_keys=True))
raise SystemExit(record.get('test', record['compile'])['exitCode'])
