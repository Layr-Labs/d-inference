from pathlib import Path
import hashlib
import json
import subprocess
import time

base = Path(__file__).resolve().parent
run = base / 'build-1'
run.mkdir()
paths = list((base / 'Sources').rglob('*.swift')) + list((base / 'Entries').rglob('*.swift'))
paths += [base / 'build.sh', Path(__file__).resolve()]
pins = [{'path': str(p), 'bytes': p.stat().st_size, 'sha256': hashlib.sha256(p.read_bytes()).hexdigest()} for p in sorted(paths)]
(run / 'source-pins.json').write_text(json.dumps(pins, indent=2) + '\n')
command = ['/bin/bash', str(base / 'build.sh'), str(run / 'artifacts')]
began = time.monotonic()
with (run / 'stdout').open('xb') as out, (run / 'stderr').open('xb') as err:
    result = subprocess.run(command, stdin=subprocess.DEVNULL, stdout=out, stderr=err, timeout=180)
unchanged = all(hashlib.sha256(Path(p['path']).read_bytes()).hexdigest() == p['sha256'] for p in pins)
receipt = {'command': command, 'exitCode': result.returncode, 'elapsedSeconds': time.monotonic() - began,
           'sourcePinsUnchanged': unchanged, 'nativeModelOrNetworkExecution': False}
(run / 'execution.json').write_text(json.dumps(receipt, indent=2) + '\n')
print(json.dumps(receipt))
assert unchanged
raise SystemExit(result.returncode)
