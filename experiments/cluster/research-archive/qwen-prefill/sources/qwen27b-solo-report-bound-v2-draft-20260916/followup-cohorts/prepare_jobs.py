"""Root-only, create-only two small jobs; reuse the unchanged native and supervisor."""
from pathlib import Path
import hashlib
import json
import os
import subprocess
from parent_settings import SSH

BASE = Path(__file__).resolve().parent
REMOTE = r'''
from pathlib import Path
import fcntl,hashlib,json,os,stat,subprocess
root=Path('/Users/developer/DarkbloomDev/qwen27b-resident-solo-report-fixed-20260916')
assert root.resolve()==root
assert value['remoteRoot']==str(root) and len(value['files'])==2

def read(path,cap):
 fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
 with os.fdopen(fd,'rb') as stream:
  info=os.fstat(stream.fileno());assert stat.S_ISREG(info.st_mode) and info.st_uid==os.getuid() and info.st_nlink==1 and 0<info.st_size<=cap
  raw=stream.read(cap+1);assert len(raw)==info.st_size
  named=path.lstat();assert (info.st_dev,info.st_ino)==(named.st_dev,named.st_ino)
 return raw

first=read(root/'supervisor/job.json',16384)
assert hashlib.sha256(first).hexdigest()==value['baseJobSHA256']
assert hashlib.sha256(read(root/'supervisor/manifest.json',1048576)).hexdigest()==value['launcherSHA256']
original=json.loads(first);prepared=[]
for expected,row in zip((2,3),value['files']):
 assert row['cohort']==expected and row['path']=='jobs/cohort-'+str(expected)+'.json'
 raw=row['raw'].encode();assert len(raw)==row['bytes']<=16384 and hashlib.sha256(raw).hexdigest()==row['sha256']
 job=json.loads(raw);assert json.dumps(job,sort_keys=True,separators=(',',':'))+'\n'==row['raw']
 assert job['run_dir']==str(root/('runs/cohort-'+str(expected))) and not Path(job['run_dir']).exists()
 assert {k:v for k,v in job.items() if k not in ('request_id','run_dir')}=={k:v for k,v in original.items() if k not in ('request_id','run_dir')}
 prepared.append((Path(row['path']).name,raw))
assert len({original['request_id']}|{json.loads(raw)['request_id'] for _,raw in prepared})==3
lease=Path('/Users/developer/.darkbloom/cluster-device/native-device.lease')
fd=os.open(lease,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
try:
 fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
 info=os.fstat(fd);named=lease.lstat()
 assert stat.S_ISREG(info.st_mode) and info.st_uid==os.getuid() and stat.S_IMODE(info.st_mode)==0o600 and info.st_nlink==1 and info.st_size==0
 assert (info.st_dev,info.st_ino)==(named.st_dev,named.st_ino)
 ps=subprocess.check_output(['/bin/ps','-axo','pid=,comm='],text=True,timeout=3)
 active=[line.strip() for line in ps.splitlines() if len(line.split(maxsplit=1))==2 and (Path(line.split(maxsplit=1)[1]).name.lower().startswith(('darkbloom','qwen')) or Path(line.split(maxsplit=1)[1]).name in ('owner-controller','cluster-inference'))]
 assert not active,active
 rootfd=os.open(root,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
 try:
  s=os.fstat(rootfd);assert stat.S_ISDIR(s.st_mode) and s.st_uid==os.getuid() and stat.S_IMODE(s.st_mode)==0o700
  os.mkdir('jobs',0o700,dir_fd=rootfd);os.fsync(rootfd)
  jobfd=os.open('jobs',os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=rootfd)
  try:
   for name,raw in prepared:
    target=os.open(name,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600,dir_fd=jobfd)
    with os.fdopen(target,'wb') as out:out.write(raw);out.flush();os.fsync(out.fileno())
    assert read(root/'jobs'/name,16384)==raw
   os.fsync(jobfd)
  finally:os.close(jobfd)
 finally:os.close(rootfd)
 final=os.fstat(fd);named=lease.lstat()
 assert (final.st_dev,final.st_ino,final.st_size)==(info.st_dev,info.st_ino,0)==(named.st_dev,named.st_ino,named.st_size)
 print(json.dumps(dict(jobsCreated=2,nativeOrModelExecuted=False,active=active,journalBytes=0,jobSHA256=[hashlib.sha256(raw).hexdigest() for _,raw in prepared])),flush=True)
finally:os.close(fd)
'''


def main():
    os.umask(0o077)
    first = json.loads((BASE.parent/'physical-source/run-1/validated-sample.json').read_bytes())
    assert first['completeCohortValidated'] is True and first['measuredCount'] == 1
    value = json.loads((BASE/'jobs.json').read_bytes())
    assert first['jobSHA256'] == value['baseJobSHA256'] and first['nativeSHA256'] == value['nativeSHA256']
    for row in value['files']:
        raw = (BASE/row['path']).read_bytes()
        assert len(raw) == row['bytes'] and hashlib.sha256(raw).hexdigest() == row['sha256']
        row['raw'] = raw.decode()
    output = BASE/'installation-1'; output.mkdir(mode=0o700)
    script = 'import json\nvalue=json.loads('+repr(json.dumps(value,separators=(',',':')))+')\n'+REMOTE
    (output/'remote-source.py').write_text(script)
    command = SSH+['-S','none','darkbloom-48','/usr/bin/python3 -B -']
    try:
        done = subprocess.run(command,input=script.encode(),capture_output=True,timeout=30)
    except subprocess.TimeoutExpired as error:
        (output/'stdout').write_bytes(error.stdout or b'');(output/'stderr').write_bytes(error.stderr or b'')
        (output/'receipt.json').write_text(json.dumps(dict(passed=False,remoteOutcomeUnknown=True))+'\n')
        raise
    (output/'stdout').write_bytes(done.stdout);(output/'stderr').write_bytes(done.stderr)
    passed=done.returncode==0 and not done.stderr and len(done.stdout)<=16384
    (output/'receipt.json').write_text(json.dumps(dict(passed=passed,exitCode=done.returncode,remoteOutcomeUnknown=not passed))+'\n')
    assert passed
    result=json.loads(done.stdout);assert result['jobsCreated']==2 and result['active']==[] and result['journalBytes']==0
    print(json.dumps(result))


if __name__=='__main__':main()
