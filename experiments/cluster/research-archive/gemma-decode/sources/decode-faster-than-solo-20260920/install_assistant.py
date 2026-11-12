"""Create-only SSH installation of the verified auxiliary artifact. No MLX."""
from pathlib import Path
import argparse
import hashlib
import json
import shlex
import signal
import subprocess
import sys
import tarfile

ROOT = Path(__file__).resolve().parent
ARTIFACT = ROOT / 'assistant-artifact'
REMOTE = '/Users/developer/DarkbloomDev/models/Gemma4-26B-assistant-bb94eae1'
sys.path.insert(0, str(ROOT.parent / 'gemma4-decode-optimization-20260920/harness-v2'))
from parent_settings import SSH

INSTALL = r'''
import hashlib,json,os,pathlib,signal,stat,sys,tarfile
signal.signal(signal.SIGALRM,lambda *_: os._exit(124)); signal.alarm(150)
root=pathlib.Path(sys.argv[1]); expected=sys.argv[2]
assert root==pathlib.Path('/Users/developer/DarkbloomDev/models/Gemma4-26B-assistant-bb94eae1')
assert root.parent.resolve()==root.parent and not root.exists()
fs=os.statvfs(root.parent); assert fs.f_bavail*fs.f_frsize > 2*1024**3
os.umask(0o077); root.mkdir(mode=0o700)
names={'manifest.json','config.json','model.safetensors'}; seen=set();total=0
with tarfile.open(fileobj=sys.stdin.buffer,mode='r|') as archive:
 for entry in archive:
  assert entry.isfile() and entry.name in names and entry.name not in seen
  assert 0<entry.size<300000000
  total+=entry.size; assert total<300000000
  seen.add(entry.name)
  with (root/entry.name).open('xb') as target:
   source=archive.extractfile(entry)
   while True:
    chunk=source.read(1024**2)
    if not chunk: break
    target.write(chunk)
assert seen==names
def digest(path):
 h=hashlib.sha256()
 with path.open('rb') as stream:
  for chunk in iter(lambda:stream.read(1024**2),b''): h.update(chunk)
 return h.hexdigest()
assert digest(root/'manifest.json')==expected
manifest=json.loads((root/'manifest.json').read_bytes())
assert manifest['schema_version']==1 and manifest['file_count']==2
assert {row['path'] for row in manifest['files']}==names-{'manifest.json'}
aggregate=hashlib.sha256()
for row in sorted(manifest['files'],key=lambda row:row['path']):
 path=root/row['path']; observed=path.lstat()
 assert stat.S_ISREG(observed.st_mode) and observed.st_nlink==1 and observed.st_size==row['size_bytes']
 value=digest(path); assert value==row['sha256']
 aggregate.update(bytes.fromhex(value))
assert aggregate.hexdigest()==manifest['aggregate_sha256']
print(json.dumps(dict(status='installed',root=str(root),manifestSHA256=expected,
 aggregateSHA256=aggregate.hexdigest(),bytes=total,nativeExecuted=False)))
'''


def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('--host', required=True, choices=['darkbloom-24', 'darkbloom-48'])
    args = parser.parse_args()
    reference = json.loads((ARTIFACT / 'reference.json').read_bytes())
    assert json.loads((ARTIFACT / 'download-receipt.json').read_bytes())['status'] == 'passed'
    manifest = (ARTIFACT / 'manifest.json').read_bytes()
    assert hashlib.sha256(manifest).hexdigest() == reference['manifest_sha256']
    receipt_path = ARTIFACT / ('installation-' + args.host + '.json')
    assert not receipt_path.exists()
    command = SSH + ['-o', 'ServerAliveInterval=5', '-o', 'ServerAliveCountMax=3', args.host,
                     shlex.join(['/usr/bin/python3', '-B', '-c', INSTALL, REMOTE,
                                           reference['manifest_sha256']])]
    process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    def deadline(*_):
        raise TimeoutError('Bounded artifact installation expired')
    signal.signal(signal.SIGALRM, deadline); signal.alarm(160)
    try:
        with tarfile.open(fileobj=process.stdin, mode='w|') as archive:
            for name in ['manifest.json', 'config.json', 'model.safetensors']:
                archive.add(ARTIFACT / name, arcname=name, recursive=False)
        process.stdin.close(); process.stdin = None
        stdout, stderr = process.communicate(timeout=120)
    except BaseException:
        process.kill(); process.wait(timeout=10)
        raise
    finally:
        signal.alarm(0)
    receipt = dict(host=args.host, exitCode=process.returncode, stdout=stdout.decode(), stderr=stderr.decode(),
                   manifestSHA256=reference['manifest_sha256'], nativeExecuted=False)
    with receipt_path.open('x') as stream:
        json.dump(receipt, stream, indent=2)
    assert process.returncode == 0 and not stderr
    print(stdout.decode(), end='')


if __name__ == '__main__':
    main()
