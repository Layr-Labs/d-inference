"""Small source installation only; fresh directory, no rsync or model launch."""
import base64
import fcntl
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys

ROOT=Path('/Users/developer/DarkbloomDev/gemma4-model-preparation-20260917')
FINAL=Path('/Users/developer/DarkbloomDev/models/Gemma4-26B')
NAMES={'artifact.py','artifact-manifest.json','binding_common.py','lease_gate.py','mtp_journal.py','target_processes.py',
       'owned_process.py','rsync_exec.py','receive_rsync.py','remote_control.py','source_guard.py','source-pins.json'}
def require(value,message):
    if not value:raise ValueError(message)
def main():
    raw=sys.stdin.buffer.read(131073);require(len(raw)<=131072,'Source install bound');value=json.loads(raw)
    require(set(value)=={'host','physicalMemoryBytes','files'} and set(value['files'])==NAMES,'Exact receiver source closure')
    require(value['host'] in ('darkbloom-24','darkbloom-48'),'Selected host')
    require(value['physicalMemoryBytes']=={'darkbloom-24':24,'darkbloom-48':48}[value['host']]*1024**3,'Closed role memory')
    memory=subprocess.run(['/usr/sbin/sysctl','-n','hw.memsize'],capture_output=True,timeout=3,check=True)
    require(not memory.stderr and memory.stdout.decode().strip()==str(value['physicalMemoryBytes']),'Actual host role memory')
    require(ROOT.parent.resolve()==ROOT.parent and FINAL.parent.resolve()==FINAL.parent,'Canonical owned parents')
    require(not os.path.lexists(ROOT) and not os.path.lexists(FINAL),'Fresh preparation/final paths required')
    space=os.statvfs(FINAL.parent);free=space.f_bavail*space.f_frsize;require(free>=15641239295+16*1024**3,'Payload+16GiB disk headroom')
    lease=Path('/Users/developer/.darkbloom/cluster-device/native-device.lease')
    require(lease.parent.resolve()==lease.parent,'Canonical lease directory')
    ds=lease.parent.lstat();require(stat.S_ISDIR(ds.st_mode) and ds.st_uid==os.geteuid() and ds.st_mode&0o077==0,'Private owned lease directory')
    fd=os.open(lease,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK|os.O_CLOEXEC)
    try:
        fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB);s=os.fstat(fd);named=lease.lstat()
        require(stat.S_ISREG(s.st_mode) and s.st_uid==os.geteuid() and s.st_nlink==1 and s.st_mode&0o077==0
            and s.st_size==0 and os.pread(fd,1,0)==b'' and (s.st_dev,s.st_ino)==(named.st_dev,named.st_ino),'Unresolved or unsafe device gate')
        os.umask(0o077);ROOT.mkdir(mode=0o700);(ROOT/'model').mkdir(mode=0o700)
        verified={}
        for name,row in sorted(value['files'].items()):
            data=base64.b64decode(row['base64'],validate=True)
            require(len(data)==row['bytes'] and hashlib.sha256(data).hexdigest()==row['sha256'],'Source hash')
            with (ROOT/name).open('xb') as out:out.write(data);out.flush();os.fsync(out.fileno())
            verified[name]={k:row[k] for k in ('bytes','sha256')}
        require((lease.parent.lstat().st_dev,lease.parent.lstat().st_ino)==(ds.st_dev,ds.st_ino),'Lease directory changed')
        result=dict(host=value['host'],preparation=str(ROOT),final=str(FINAL),sourceFiles=verified,availableBytes=free,
                    gate=dict(path=str(lease),directoryDevice=ds.st_dev,directoryInode=ds.st_ino,fileDevice=s.st_dev,fileInode=s.st_ino),
                    journalMutated=False,modelOrReceiverLaunched=False)
        with (ROOT/'preparation.json').open('x') as out:json.dump(result,out,sort_keys=True);out.write('\n');out.flush();os.fsync(out.fileno())
        print(json.dumps(result,sort_keys=True))
    finally:os.close(fd)
if __name__=='__main__':main()
