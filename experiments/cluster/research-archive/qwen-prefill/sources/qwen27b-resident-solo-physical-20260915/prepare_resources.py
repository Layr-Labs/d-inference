"""Authorized disk-cache purge and retained resource observations before the 27B diagnostic."""
import hashlib
import json
import os
from pathlib import Path
import shlex
import stat
import subprocess
import sys
import time

BASE = Path(__file__).resolve().parent
PARENT = BASE.parent / 'qwen27b-8k-lookahead-owner-qualification-20260915'
sys.path.insert(0, str(PARENT))
from parent_settings import SSH

REMOTE = r'''
import fcntl, hashlib, json, os, signal, stat, subprocess, sys, time
from pathlib import Path
root=Path('/Users/developer/DarkbloomDev/qwen27b-8k-lookahead-owner-validation-20260915')
assert hashlib.sha256((root/'reference_resources.py').read_bytes()).hexdigest()=='ef10b3209e22e1d71586c0616ddd2d3e9c40522453393e57cc9d8e0156b2b354'
sys.path.insert(0,str(root))
from reference_resources import sample_local,validate_local
secret=sys.stdin.buffer.readline(8193)
assert 1<len(secret)<=8192 and secret.endswith(b'\n')
lease=Path('/Users/developer/.darkbloom/cluster-device/native-device.lease')
fd=os.open(lease,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
try:
 fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
 info=os.fstat(fd);named=lease.lstat()
 assert stat.S_ISREG(info.st_mode) and info.st_uid==os.geteuid() and stat.S_IMODE(info.st_mode)==0o600 and info.st_nlink==1 and info.st_size==0
 assert (info.st_dev,info.st_ino)==(named.st_dev,named.st_ino)
 ps=subprocess.check_output(['/bin/ps','-axo','pid=,comm='],text=True,timeout=3)
 active=[line.strip() for line in ps.splitlines() if len(line.split(maxsplit=1))==2 and (Path(line.split(maxsplit=1)[1]).name.lower().startswith(('darkbloom','qwen')) or Path(line.split(maxsplit=1)[1]).name in ('owner-controller','cluster-inference'))]
 assert active==[],active
 before=sample_local();validate_local(before)
 record=dict(before=before,active=active,canonicalJournal=dict(device=info.st_dev,inode=info.st_ino,bytes=0),nativeOrModelExecuted=False)
 child=subprocess.Popen(['/usr/bin/sudo','-k','-S','-p','','/usr/sbin/purge'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
 record['purgePID']=child.pid;started=time.monotonic()
 try:
  out,err=child.communicate(secret,timeout=30)
 except BaseException as error:
  record['error']=type(error).__name__
  if child.returncode is None:
   try:os.killpg(child.pid,signal.SIGKILL)
   except ProcessLookupError:pass
  out,err=child.communicate(timeout=5)
 finally:
  record.update(purgeExitCode=child.returncode,purgeSeconds=time.monotonic()-started,reaped=child.returncode is not None)
  if child.returncode is not None:
   try:os.killpg(child.pid,0)
   except ProcessLookupError:record['groupAbsent']=True
   else:record['groupAbsent']=False
 record['stdout']=out.decode(errors='replace').replace(secret.decode().rstrip('\n'),'[REDACTED]')
 record['stderr']=err.decode(errors='replace').replace(secret.decode().rstrip('\n'),'[REDACTED]')
 after=sample_local();record['after']=after
 final=os.fstat(fd);named=lease.lstat()
 record['journalUnchanged']=(final.st_dev,final.st_ino,final.st_size)==(info.st_dev,info.st_ino,0)==(named.st_dev,named.st_ino,named.st_size)
 record['passed']=child.returncode==0 and not out and not err and record.get('groupAbsent') is True and record['journalUnchanged'] and 'error' not in record
 validate_local(after)
 print(json.dumps(record),flush=True)
 assert record['passed']
finally:os.close(fd)
'''


def main():
    directory = BASE / 'resource-preparation-1'
    directory.mkdir(mode=0o700)
    credential = BASE.parent.parent / 'machines/CREDENTIALS.private.md'
    info = credential.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600:
        raise ValueError('Private credential file ownership/mode differs')
    rows = [[cell.strip().strip('`') for cell in line.strip().strip('|').split('|')]
            for line in credential.read_text().splitlines() if line.startswith('|')]
    secret = (rows[2][[cell.lower() for cell in rows[0]].index('password')] + '\n').encode()
    for rank, host in enumerate(['darkbloom-24', 'darkbloom-48']):
        if rank != 1:
            continue
        command = SSH + ['-S', 'none', host, shlex.join(['/usr/bin/python3', '-B', '-c', REMOTE])]
        started = time.monotonic()
        result = subprocess.run(command, input=secret, capture_output=True, timeout=50)
        (directory / ('rank' + str(rank) + '.stdout')).write_bytes(result.stdout)
        (directory / ('rank' + str(rank) + '.stderr')).write_bytes(result.stderr)
        receipt = dict(host=host, exitCode=result.returncode, elapsedSeconds=time.monotonic() - started,
                       remoteScriptSHA256=hashlib.sha256(REMOTE.encode()).hexdigest(),
                       stdoutSHA256=hashlib.sha256(result.stdout).hexdigest(), stderrSHA256=hashlib.sha256(result.stderr).hexdigest())
        (directory / ('rank' + str(rank) + '.receipt.json')).write_text(json.dumps(receipt, indent=2) + '\n')
        if result.returncode != 0 or result.stderr or len(result.stdout) > 131072:
            raise ValueError('Resource preparation failed for rank ' + str(rank) + '; raw result retained')
        value = json.loads(result.stdout)
        if not value['passed']:
            raise ValueError('Remote resource preparation refused')
        print(json.dumps(dict(rank=rank, passed=True, beforeFreeBytes=value['before']['actualFreeBytes'],
                              afterFreeBytes=value['after']['actualFreeBytes'])), flush=True)


if __name__ == '__main__':
    os.umask(0o077)
    main()
