"""One inherited canonical lock, then same-PID exec. Never writes the journal."""
import argparse
import fcntl
import os
from pathlib import Path
import stat
import sys
import time
from binding_common import parse, require, same
from binding_inputs import snapshot
from gemma_inputs import PRODUCT, REMOTE, write_json
from mtp_journal import device_directory
from target_processes import observe


def acquire(directory):
    require(directory.resolve() == directory, 'Canonical device directory contains a link')
    parent = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    fd = None
    try:
        ds = os.fstat(parent)
        require(ds.st_uid == os.geteuid() and ds.st_mode & 0o077 == 0, 'Unsafe canonical directory')
        fd = os.open('native-device.lease', os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK, dir_fd=parent)
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        value = os.fstat(fd); named = os.stat('native-device.lease', dir_fd=parent, follow_symlinks=False)
        require(stat.S_ISREG(value.st_mode) and value.st_uid == os.geteuid() and value.st_nlink == 1
                and value.st_mode & 0o077 == 0 and value.st_size == 0 and os.pread(fd,1,0)==b'', 'Canonical journal is unsafe or unresolved')
        identity = lambda s:(s.st_dev,s.st_ino,s.st_mode,s.st_nlink,s.st_size,s.st_mtime_ns,s.st_ctime_ns)
        same(identity(value),identity(named),'Canonical path identity')
        same((directory.lstat().st_dev,directory.lstat().st_ino),(ds.st_dev,ds.st_ino),'Canonical directory identity')
        return fd, dict(path=str(directory/'native-device.lease'),directoryDevice=ds.st_dev,directoryInode=ds.st_ino,
            fileDevice=value.st_dev,fileInode=value.st_ino,bytes=0,leaseFD=fd,ownerPID=os.getpid(),
            exclusiveLockHeld=True,inheritedAcrossExec=True,journalMutationPerformed=False,protocolReleaseACK=False)
    except BaseException:
        if fd is not None: os.close(fd)
        raise
    finally: os.close(parent)


def main():
    p=argparse.ArgumentParser(allow_abbrev=False);p.add_argument('--launch',required=True);p.add_argument('--launch-sha256',required=True)
    a=p.parse_args(); path=Path(a.launch)
    require(path.parent.parent.parent == REMOTE and path.name=='launch.json','Wrong launch path')
    info=snapshot(path,16384);same(info['sha256'],a.launch_sha256,'launch pin');launch=parse(info['raw'])
    require(set(launch)=={'binary','job','environment','binaryIdentity','jobSHA256','nativeOperation','localMTPConfigSHA256','remoteMTPConfigSHA256','role'},'Launch fields')
    binary=Path(launch['binary']);same(binary,REMOTE/'bundle'/PRODUCT,'Exact executable')
    require(binary.parent.resolve()==binary.parent,'Executable parent link')
    s=binary.lstat();same(list((s.st_dev,s.st_ino,s.st_mode,s.st_size,s.st_mtime_ns,s.st_ctime_ns)),launch['binaryIdentity'],'Verified binary changed')
    require(stat.S_ISREG(s.st_mode) and s.st_nlink==1 and s.st_uid==os.geteuid(),'Unsafe executable')
    job=Path(launch['job']);same(job,path.parent/'job.json','Exact job path')
    same(snapshot(job,16384)['sha256'],launch['jobSHA256'],'Job changed before gate')
    config=path.parent/'local-mtp.json'
    same(snapshot(config,16384)['sha256'],launch['localMTPConfigSHA256'],'Local MTP config changed before gate')
    remote=path.parent/'remote-mtp.json'
    same(snapshot(remote,16384)['sha256'],launch['remoteMTPConfigSHA256'],'Remote config changed before gate')
    require(launch['nativeOperation']=='execute-remote-mtp-dense-head' and launch['role'] in ('assistant','target'),'Native operation/role')
    wrapper=parse(snapshot(remote,16384)['raw'])
    require(wrapper['role']==launch['role'] and wrapper['localMTPJob']==str(config),'Remote role/config path')
    fd, record=acquire(device_directory())
    try:
        processes=observe(time.monotonic()+4)
        require(not processes['prohibited'],'A known native/owner is already running under the gate')
        record['processObservation']=processes
        # All other opened descriptors retain close-on-exec. This is the only
        # descriptor deliberately retained by the exact native process.
        os.set_inheritable(fd,True);require(os.get_inheritable(fd),'Lease descriptor is not inheritable')
        write_json(path.parent/'gate.json',record)
        s2=binary.lstat();same((s2.st_dev,s2.st_ino,s2.st_mode,s2.st_size,s2.st_mtime_ns,s2.st_ctime_ns),tuple(launch['binaryIdentity']),'Executable changed before exec')
        same(snapshot(config,16384)['sha256'],launch['localMTPConfigSHA256'],'Local MTP config changed before exec')
        same(snapshot(job,16384)['sha256'],launch['jobSHA256'],'Job changed before exec')
        same(snapshot(remote,16384)['sha256'],launch['remoteMTPConfigSHA256'],'Remote config changed before exec')
        arguments=[str(binary),'--execute-remote-mtp-dense-head',str(remote)]
        os.execve(str(binary),arguments,launch['environment'])
    finally: os.close(fd)


if __name__=='__main__': main()
