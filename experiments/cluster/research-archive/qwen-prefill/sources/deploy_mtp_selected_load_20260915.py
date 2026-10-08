"""Install the frozen loading-only fixture in a fresh private directory on rank1."""
from pathlib import Path
import hashlib
import json
import os
import shlex
import shutil
import subprocess
import uuid

ROOT = Path('/Users/developer/DarkbloomDev/cluster-research')
NATIVE = ROOT / 'qwen-resident-mtp-selected-load-draft-20260915/handoff'
LAUNCHER = ROOT / 'qwen-resident-mtp-selected-load-supervisor-20260915'
OUT = ROOT / 'qwen-mtp-selected-load-physical-20260915'
REMOTE = '/Users/developer/DarkbloomDev/qwen-mtp-selected-load-20260915'
HOST = 'darkbloom-48'
SSH = ['ssh', '-T', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8']
LAUNCHER_PIN = '04a571bd3cf60a268c3a9b3723c9901aa3498feeb409993d8e0c9480b301e441'


def sha(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def save(path, value):
    with path.open('x') as stream:
        stream.write(json.dumps(value, indent=2, sort_keys=True) + '\n')


def verify_manifest(root, expected, key):
    assert sha(root / 'manifest.json') == expected
    value = json.loads((root / 'manifest.json').read_text())
    for item in value[key]:
        rel = Path(item['path'])
        assert not rel.is_absolute() and '..' not in rel.parts
        assert sha(root / rel) == item['sha256'], str(rel)
        assert (root / rel).stat().st_size == item['bytes'], str(rel)
    return value


REMOTE_CREATE = r'''
from pathlib import Path
import json,os,sys
p=Path(json.load(sys.stdin)['root'])
assert p.parent.resolve()==p.parent and p.parent.is_dir()
assert not os.path.lexists(p)
p.mkdir(mode=0o700)
print(json.dumps({'created':str(p),'nativeExecuted':False}))
'''

REMOTE_VERIFY = r'''
from pathlib import Path
import hashlib,json,os,stat,sys
x=json.load(sys.stdin);root=Path(x['root']);seen=set();checks=[]
assert root.resolve()==root and root.stat().st_uid==os.geteuid()
for row in x['files']:
 rel=Path(row['path']);assert not rel.is_absolute() and '..' not in rel.parts
 p=root/rel;s=p.lstat()
 assert stat.S_ISREG(s.st_mode) and s.st_uid==os.geteuid() and s.st_mode&0o077==0
 assert p.resolve()==p and s.st_size==row['bytes']
 h=hashlib.sha256()
 with p.open('rb') as f:
  for chunk in iter(lambda:f.read(1024*1024),b''):h.update(chunk)
 assert h.hexdigest()==row['sha256']
 assert stat.S_IMODE(s.st_mode)==row['mode']
 seen.add(row['path']);checks.append({'path':row['path'],'sha256':h.hexdigest(),'bytes':s.st_size})
actual=set()
for parent,dirs,files in os.walk(root,followlinks=False):
 for name in dirs:
  p=Path(parent)/name;s=p.lstat()
  assert stat.S_ISDIR(s.st_mode) and s.st_uid==os.geteuid() and s.st_mode&0o077==0
 for name in files:actual.add((Path(parent)/name).relative_to(root).as_posix())
assert actual==seen
(root/'runs').mkdir(mode=0o700)
print(json.dumps({'root':str(root),'verified':checks,'nativeExecuted':False,'modelPayloadRead':False}))
'''


def remote(label, code, payload):
    command = SSH + [HOST, shlex.join(['/usr/bin/python3', '-c', code])]
    result = subprocess.run(command, input=json.dumps(payload), text=True, capture_output=True, timeout=90)
    save(OUT / (label + '.json'), dict(host=HOST, exitCode=result.returncode,
        stdout=result.stdout, stderr=result.stderr, nativeExecuted=False))
    assert result.returncode == 0, label
    return json.loads(result.stdout)


def main():
    native = verify_manifest(NATIVE, 'ccf67b3eae403916471b6f309cf17f8bf475d4477f6cef2da2e5d7b0bbc069d7', 'members')
    launcher = verify_manifest(LAUNCHER, LAUNCHER_PIN, 'files')
    OUT.mkdir(mode=0o700)
    package = OUT / 'package'; package.mkdir(mode=0o700)
    sources = [(NATIVE / 'bundle/bundle.json', 'bundle/bundle.json')]
    bundle = json.loads((NATIVE / 'bundle/bundle.json').read_text())
    sources += [(NATIVE / 'bundle' / item['path'], 'bundle/' + item['path']) for item in bundle['files']]
    sources += [(LAUNCHER / item['path'], 'launcher/' + item['path']) for item in launcher['files']]
    sources.append((LAUNCHER / 'manifest.json', 'launcher/manifest.json'))
    rows = []
    for source, relative in sources:
        target = package / relative; target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        assert not target.exists()
        shutil.copyfile(source, target)
        mode = 0o700 if relative == 'bundle/MTPSelectedLoadCheck' else 0o600
        target.chmod(mode)
        assert sha(target) == sha(source)
        rows.append(dict(path=relative, bytes=target.stat().st_size, sha256=sha(target), mode=mode))
    job = json.loads((LAUNCHER / 'example-job.json').read_text())
    job.update(run_id=str(uuid.uuid4()), deployment=REMOTE + '/bundle', run_dir=REMOTE + '/runs/physical-1')
    raw = json.dumps(job, sort_keys=True, separators=(',', ':'), allow_nan=False).encode() + b'\n'
    target = package / 'job-1.json'; target.write_bytes(raw); target.chmod(0o600)
    rows.append(dict(path='job-1.json', bytes=len(raw), sha256=sha(target), mode=0o600))
    for directory, _, _ in os.walk(package):
        Path(directory).chmod(0o700)
    save(OUT / 'package.json', dict(files=rows, remoteRoot=REMOTE, host=HOST,
        launcherSHA256=LAUNCHER_PIN, jobSHA256=sha(target), sourceManifestMembers=len(native['members']),
        nativeExecuted=False, modelPayloadRead=False))
    remote('create', REMOTE_CREATE, dict(root=REMOTE))
    command = ['scp', '-q', '-p', '-r', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8',
               str(package / 'bundle'), str(package / 'launcher'), str(target), HOST + ':' + REMOTE + '/']
    copied = subprocess.run(command, capture_output=True, text=True, timeout=180)
    save(OUT / 'copy.json', dict(command=command, exitCode=copied.returncode,
        stdout=copied.stdout, stderr=copied.stderr))
    assert copied.returncode == 0
    result = remote('verify', REMOTE_VERIFY, dict(root=REMOTE, files=rows))
    print(json.dumps(dict(host=HOST, root=REMOTE, verifiedFiles=len(result['verified']),
        nativeExecuted=False, jobSHA256=sha(target), launcherSHA256=LAUNCHER_PIN)), flush=True)


if __name__ == '__main__':
    main()
