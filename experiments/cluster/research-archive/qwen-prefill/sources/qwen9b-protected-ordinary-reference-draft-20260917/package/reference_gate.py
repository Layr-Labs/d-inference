"""Inherited canonical exclusion for the existing full-reference executable."""
import argparse
import fcntl
import os
from pathlib import Path
import stat
import time
from binding_common import parse, require, same
from binding_inputs import snapshot
from reference_inputs import native_spec, validate_job, write_json
from reference_settings import REMOTE, NATIVE_DIRECTORY, require_short
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
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('--launch', required=True); parser.add_argument('--launch-sha256', required=True)
    args = parser.parse_args()
    path = Path(args.launch)
    same(path, REMOTE / 'runs/reference-1/launch.json', 'Exact launch namespace')
    raw = snapshot(path, 16384); same(raw['sha256'], args.launch_sha256, 'Launch binding')
    launch = parse(raw['raw'])
    require(set(launch) == {'binary', 'binaryIdentity', 'job', 'jobSHA256'}, 'Launch fields')
    job_path = path.parent / 'job.json'; same(launch['job'], str(job_path), 'Exact job path')
    raw_job = snapshot(job_path, 16384); same(raw_job['sha256'], launch['jobSHA256'], 'Exact job bytes')
    job = validate_job(parse(raw_job['raw'])); require_short(job)
    spec = native_spec(job)
    binary = NATIVE_DIRECTORY / 'cluster-inference'
    same(launch['binary'], str(binary), 'Exact reference executable')
    same(spec.argv[0], str(binary), 'Actual native argv')
    require(binary.parent.resolve() == binary.parent, 'Executable parent link')
    stamp = lambda s:(s.st_dev,s.st_ino,s.st_mode,s.st_size,s.st_mtime_ns,s.st_ctime_ns)
    named = binary.lstat()
    same(list(stamp(named)), launch['binaryIdentity'], 'Previously verified binary changed')
    require(stat.S_ISREG(named.st_mode) and named.st_nlink == 1 and named.st_uid == os.geteuid(), 'Unsafe reference executable')
    fd, record = acquire(device_directory())
    try:
        actual = observe(time.monotonic() + 4)
        require(not actual['prohibited'], 'A native/owner is live under canonical exclusion')
        record['processObservation'] = actual
        os.set_inheritable(fd, True); require(os.get_inheritable(fd), 'Lease FD did not become inheritable')
        write_json(path.parent / 'gate.json', record)
        same(stamp(binary.lstat()), tuple(launch['binaryIdentity']), 'Executable changed before exec')
        os.execve(str(binary), list(spec.argv), spec.env)
    finally:
        os.close(fd)


if __name__ == '__main__':
    main()
