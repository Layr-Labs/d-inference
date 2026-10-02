
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
 before=sample_local()
 assert before['pressureLevel']==1 and before['acPower'] is True and float(before['reportedSwapBytes'])==0
 assert type(before['actualFreeBytes']) is int and before['actualFreeBytes']>=0
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
