"""One-shot private stdin; never pass secret bytes through PipeWorkers logging."""
import hashlib
import os
from pathlib import Path
import select
import stat
import time
from binding_common import require
from gemma_inputs import REMOTE

def commitment(data):return hashlib.sha256(b'lab-record-secret-commitment/v1\0'+data).hexdigest()

def secret_path(native):return REMOTE/'private-secrets'/(native['runID']+'-'+str(native['rank']))

def read_stdin(wanted):
    deadline=time.monotonic()+5;value=bytearray()
    try:
        while len(value)<33:
            require(time.monotonic()<deadline,'Lab secret input deadline')
            if not select.select([0],[],[],min(.1,max(0,deadline-time.monotonic())))[0]:continue
            part=os.read(0,33-len(value))
            if not part:break
            value.extend(part)
        require(len(value)==32 and commitment(value)==wanted,'Lab secret length/commitment')
        return value
    except BaseException:
        value[:]=b'\0'*len(value);raise

def create(native):
    path=secret_path(native);path.parent.mkdir(mode=0o700,exist_ok=True)
    ds=path.parent.lstat();require(path.parent.resolve()==path.parent and stat.S_ISDIR(ds.st_mode) and ds.st_uid==os.geteuid() and ds.st_mode&0o077==0,'Lab private directory')
    value=read_stdin(native['secretCommitmentSHA256'])
    try:
        fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
        try:
            require(os.write(fd,value)==32,'Lab secret private write');os.fsync(fd)
            info=os.fstat(fd);return path,(info.st_dev,info.st_ino)
        except BaseException:
            own=os.fstat(fd);named=path.lstat()
            require((own.st_dev,own.st_ino)==(named.st_dev,named.st_ino),'Lab failed secret creation identity')
            path.unlink();raise
        finally:os.close(fd)
    finally:value[:]=b'\0'*len(value)

def cleanup(path,identity):
    try:s=path.lstat()
    except FileNotFoundError:return
    require((s.st_dev,s.st_ino)==identity and stat.S_ISREG(s.st_mode) and s.st_uid==os.geteuid() and s.st_nlink==1 and s.st_mode&0o077==0,'Lab secret cleanup identity')
    path.unlink()

def install_stdin(native):
    path=secret_path(native)
    require(path.parent.resolve()==path.parent,'Lab secret parent link')
    fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_CLOEXEC)
    try:
        s=os.fstat(fd);named=path.lstat()
        require(stat.S_ISREG(s.st_mode) and s.st_uid==os.geteuid() and s.st_mode&0o077==0 and s.st_nlink==1 and s.st_size==32 and
                (s.st_dev,s.st_ino)==(named.st_dev,named.st_ino),'Lab private secret identity')
        value=os.pread(fd,33,0)
        require(len(value)==32 and commitment(value)==native['secretCommitmentSHA256'],'Lab private secret commitment')
        # Same-PID gate opens first, unlinks that exact one-shot file, then execs
        # the native process with FD0. The worker stdin transcript stays empty.
        path.unlink();os.dup2(fd,0,inheritable=True)
    finally:os.close(fd)
