"""Root-owned native build receipt; never loads a model or contacts a peer."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import time

package, output = map(Path, sys.argv[1:])
repo = Path('/Users/developer/DarkbloomDev/d-inference')
shared = package.parent / 'darkbloom-cluster'
metallib = repo.parent / 'cluster-research/resident-cache-off-package-20260915/bundle/mlx.metallib'
metal_sha = '2129f6132794d84243c02631bc7478417dba0e0dbd10467beab56c11bf20bdd2'
output.mkdir(parents=True, exist_ok=False)

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

paths = [Path(__file__), package / 'Package.swift', package / 'Package.resolved',
         package / 'build-native-worker.sh', shared / 'Package.swift', shared / 'Package.resolved']
paths += list((package / 'Sources').rglob('*.swift'))
for module in ['DarkbloomClusterProtocol', 'DarkbloomClusterBootstrap', 'DarkbloomClusterRuntime']:
    paths += list((shared / 'Sources' / module).glob('*.swift'))
previous = json.loads((repo.parent / 'cluster-research/shared-native-worker-main-integration-20260915/native-build-3/execution.json').read_text())
paths += [repo / item['path'] for item in previous['sourcePins'] if item['path'].startswith('libs/mlx-')]
paths = sorted(set(paths))
pins = {str(path): sha(path) for path in paths}
assert sha(metallib) == metal_sha
args = ['/bin/bash', str(package / 'build-native-worker.sh'), str(package), str(metallib), metal_sha]
receipt = dict(atUTC=datetime.now(timezone.utc).isoformat(), argv=args, sourcePins=pins,
               noModelOrGPUExecution=True)
(output / 'input.json').write_text(json.dumps(receipt, indent=2) + '\n')
started = time.monotonic()
with (output / 'build.stdout').open('wb') as stdout, (output / 'build.stderr').open('wb') as stderr:
    run = subprocess.run(args, stdout=stdout, stderr=stderr, timeout=900)
receipt.update(exitCode=run.returncode, elapsedSeconds=time.monotonic() - started,
               sourcePinsUnchanged=all(sha(Path(path)) == digest for path, digest in pins.items()))
if run.returncode == 0:
    binary = package / '.build-native-worker/arm64-apple-macosx/release/darkbloom-cluster-worker'
    symbols = subprocess.run(['/usr/bin/nm', '-a', str(binary)], capture_output=True, check=True).stdout
    callback = any(line.split()[-2:] == [b'T', b'_mlx_distributed_init_jaccl_with_bootstrap']
                   for line in symbols.splitlines())
    receipt.update(nativePath=str(binary), nativeSHA256=sha(binary),
                   ownerCallbackNativeSymbolPresent=callback,
                   metallibSHA256=sha(binary.parent / 'mlx.metallib'))
    (output / 'bootstrap-symbols.txt').write_bytes(b'\n'.join(line for line in symbols.splitlines()
        if line.split()[-2:] == [b'T', b'_mlx_distributed_init_jaccl_with_bootstrap']) + b'\n')
receipt['streams'] = {path.name: dict(bytes=path.stat().st_size, sha256=sha(path))
                      for path in [output / 'build.stdout', output / 'build.stderr']}
(output / 'execution.json').write_text(json.dumps(receipt, indent=2) + '\n')
print(json.dumps({key: value for key, value in receipt.items() if key != 'sourcePins'}, indent=2))
if run.returncode:
    print((output / 'build.stderr').read_text()[-10000:])
    print((output / 'build.stdout').read_text()[-5000:])
sys.exit(run.returncode or (0 if receipt['sourcePinsUnchanged'] and receipt['ownerCallbackNativeSymbolPresent'] else 1))
