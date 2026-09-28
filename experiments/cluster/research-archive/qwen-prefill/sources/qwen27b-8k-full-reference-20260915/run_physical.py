"""Copy, run, and collect one fresh cut16 reference using the existing d717 native."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tarfile
import time

from owned_process import invoke_controller

BASE = Path(__file__).resolve().parent
sys.path.insert(0, str(BASE.parent / 'qwen27b-owner-load-operands-rerun-20260915'))
from parent_settings import SSH

REMOTE_RUN = r'''
from pathlib import Path
import fcntl,hashlib,json,os,stat,subprocess,sys
root=Path('/Users/developer/DarkbloomDev/qwen-registered-generation-reference-20260915')
launcher=root/'supervisor-27b-8k-owned'
assert launcher.resolve()==launcher
assert hashlib.sha256((launcher/'manifest.json').read_bytes()).hexdigest()=='cb3ae16e52f3469a255a5ff0a5a679365b9ac6b3c1370b4d197b8c66cf2035ef'
sys.path.insert(0,str(launcher));sys.dont_write_bytecode=True
from reference_resources import sample_local,validate_local
ps=subprocess.check_output(['/bin/ps','-axo','pid=,comm='],text=True,timeout=3)
names={'darkbloom','cluster-inference','darkbloom-cluster-worker','darkbloom-owner-qualification','owner-controller'}
active=[s.strip() for s in ps.splitlines() if len(s.split(maxsplit=1))==2 and Path(s.split(maxsplit=1)[1]).name in names]
assert not active,active
journal=Path('/Users/developer/.darkbloom/cluster-device/native-device.lease')
fd=os.open(journal,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
try:
 fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB);info=os.fstat(fd);named=journal.lstat()
 assert stat.S_ISREG(info.st_mode) and info.st_uid==os.geteuid() and stat.S_IMODE(info.st_mode)==0o600 and info.st_nlink==1 and info.st_size==0
 assert (info.st_dev,info.st_ino)==(named.st_dev,named.st_ino)
finally:os.close(fd)
resource=sample_local();validate_local(resource)
print(json.dumps(dict(kind='root_cut16_reference_preflight',active=active,journalBytes=0,resource=resource)),flush=True)
os.chdir(launcher)
os.execv('/usr/bin/python3',['/usr/bin/python3','-B',str(launcher/'run_reference.py'),'--job',str(launcher/'example-job.json'),'--job-sha256','69dc4e329e88fa26e5d28751568b74ffb3215f14d19311732e0a68ed6b804dbf','--launcher-sha256','cb3ae16e52f3469a255a5ff0a5a679365b9ac6b3c1370b4d197b8c66cf2035ef'])
'''

REMOTE_COLLECT = r'''
from pathlib import Path
import base64,hashlib,json,os,stat,subprocess
p=Path('/Users/developer/DarkbloomDev/qwen-registered-generation-reference-20260915/runs/long-27b-cut16-1')
assert p.resolve()==p and p.is_dir()
allowed={'job.json','prompt.json','owner.json','resources.jsonl','terminal.json','native/worker-0.stdin','native/worker-0.stdout','native/worker-0.stderr'}
def identity(s):return (s.st_dev,s.st_ino,s.st_size,s.st_mtime_ns,s.st_ctime_ns)
items=[];files=sorted(x for x in p.rglob('*') if not x.is_dir())
assert len(files)<=8
for f in files:
 name=str(f.relative_to(p));assert name in allowed
 fd=os.open(f,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
 try:
  before=os.fstat(fd);assert stat.S_ISREG(before.st_mode) and before.st_uid==os.geteuid() and 0<=before.st_size<=16*1024*1024
  chunks=[];remaining=before.st_size
  while remaining:
   block=os.read(fd,min(remaining,1048576));assert block;chunks.append(block);remaining-=len(block)
  assert os.read(fd,1)==b'' and identity(before)==identity(os.fstat(fd))==identity(f.lstat())
  raw=b''.join(chunks)
  items.append(dict(path=name,bytes=len(raw),sha256=hashlib.sha256(raw).hexdigest(),identity=identity(before),data=base64.b64encode(raw).decode()))
 finally:os.close(fd)
assert sum(x['bytes'] for x in items)<=24*1024*1024
assert files==sorted(x for x in p.rglob('*') if not x.is_dir())
for x in items:assert tuple(x['identity'])==identity((p/x['path']).lstat())
ps=subprocess.check_output(['/bin/ps','-axo','pid=,comm='],text=True,timeout=3)
active=[]
for line in ps.splitlines():
 parts=line.strip().split(maxsplit=1)
 if len(parts)==2:
  name=Path(parts[1]).name.lower()
  if name.startswith(('darkbloom','qwen')) or name in {'cluster-inference','owner-controller'}:active.append(line.strip())
j=Path('/Users/developer/.darkbloom/cluster-device/native-device.lease');s=j.lstat()
assert stat.S_ISREG(s.st_mode) and s.st_uid==os.geteuid() and s.st_size<=65536
print(json.dumps(dict(files=items,active=active,journalBytes=s.st_size)))
'''


def pin(path):
    raw = path.read_bytes()
    return dict(bytes=len(raw), sha256=hashlib.sha256(raw).hexdigest())


def verify():
    for name, expected in json.loads((BASE / 'manifest.json').read_bytes())['files'].items():
        if pin(BASE / name) != expected:
            raise ValueError('Frozen preparation changed: ' + name)


def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('action', choices=('copy', 'run', 'collect'))
    action = parser.parse_args().action
    verify()
    output = BASE / ('physical-' + action + '-1')
    output.mkdir(mode=0o700)
    payload = None
    if action == 'copy':
        raw = (BASE / 'deployment.json').read_bytes()
        deployment = json.loads(raw)
        assert raw.endswith(b'\n') and raw.count(b'\n') == 1 and len(deployment['files']) == 65
        payload = output / 'deployment.payload'
        with payload.open('xb') as stream:
            stream.write(raw)
            with tarfile.open(fileobj=stream, mode='w|', format=tarfile.USTAR_FORMAT) as archive:
                for name, row in sorted(deployment['files'].items()):
                    source = Path(row['source'])
                    assert pin(source) == {key: row[key] for key in ('bytes', 'sha256')}
                    item = tarfile.TarInfo(name)
                    item.size, item.mode, item.mtime = row['bytes'], row['mode'], 0
                    with source.open('rb') as data:
                        archive.addfile(item, data)
        code = (BASE / 'install_new_tree.py').read_text()
    else:
        code = REMOTE_RUN if action == 'run' else REMOTE_COLLECT
    argv = SSH + ['-S', 'none', 'darkbloom-48', shlex.join(['/usr/bin/python3', '-B', '-c', code])]
    receipt = dict(action=action, remoteCodeSHA256=hashlib.sha256(code.encode()).hexdigest(),
                   passed=False, nativeRequested=action == 'run')
    started = time.monotonic()
    source = None
    try:
        if payload is not None:
            source = payload.open('rb')
        with (output / 'stdout').open('xb') as stdout, (output / 'stderr').open('xb') as stderr:
            invoke_controller(argv, stdout, stderr, receipt, timeout=420 if action == 'run' else 45,
                              stdin=source if source is not None else subprocess.DEVNULL)
        assert receipt['exitCode'] == 0 and receipt['reaped'] and receipt['groupAbsent']
        assert (output / 'stderr').stat().st_size == 0
        assert (output / 'stdout').stat().st_size <= (36 * 1024 * 1024 if action == 'collect' else 131072)
        if action == 'copy':
            value = json.loads((output / 'stdout').read_bytes())
            assert value['manifestSHA256'] == hashlib.sha256(raw).hexdigest()
            assert value['verified'] == {name: {key: row[key] for key in ('bytes', 'sha256')}
                                          for name, row in deployment['files'].items()}
            assert value['modelOrOwnerLaunched'] is False and value['existingInputsModified'] is False
            receipt['verifiedFiles'] = len(value['verified'])
        elif action == 'collect':
            packet = json.loads((output / 'stdout').read_bytes())
            returned = output / 'returned'
            returned.mkdir(mode=0o700)
            for item in packet['files']:
                part = Path(item['path'])
                assert not part.is_absolute() and '..' not in part.parts
                raw = base64.b64decode(item['data'], validate=True)
                assert len(raw) == item['bytes'] and hashlib.sha256(raw).hexdigest() == item['sha256']
                target = returned / part
                target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                with target.open('xb') as stream:
                    stream.write(raw)
            receipt.update(verifiedFiles=len(packet['files']), active=packet['active'], journalBytes=packet['journalBytes'])
            assert packet['active'] == [] and packet['journalBytes'] == 0
        verify()
        receipt['passed'] = True
    finally:
        if source is not None:
            source.close()
        receipt.update(elapsedSeconds=time.monotonic() - started,
                       stdout=pin(output / 'stdout'), stderr=pin(output / 'stderr'))
        (output / 'execution.json').write_text(json.dumps(receipt, indent=2, sort_keys=True) + '\n')
    print(json.dumps(receipt, sort_keys=True))


if __name__ == '__main__':
    os.umask(0o077)
    main()
