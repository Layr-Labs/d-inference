"""Bounded read-only collection; does not repair a journal or signal processes."""
import base64
import hashlib
import json
import os
from pathlib import Path
import stat
import sys
import time

ROOT=Path('/Users/developer/DarkbloomDev/collective-native-allocation-check-48-20260916')
sys.dont_write_bytecode=True
sys.path.insert(0,str(ROOT))
from mtp_journal import device_directory, observe as observe_journal
from target_processes import observe as observe_processes
from allocation_result import CASES

assert len(sys.argv)==3 and sys.argv[1] in CASES and sys.argv[2] in tuple(str(x) for x in range(1,10))
run=ROOT/'runs'/(sys.argv[1]+'-'+sys.argv[2])
assert run.resolve()==run and run.is_dir()
files={}; total=0
names=sorted(run.rglob('*'))
for path in names:
    named=path.lstat()
    assert not stat.S_ISLNK(named.st_mode)
    if stat.S_ISDIR(named.st_mode): continue
    assert path.parent.resolve()==path.parent
    descriptor=os.open(path,os.O_RDONLY|os.O_NOFOLLOW)
    try:
        before=os.fstat(descriptor)
        assert stat.S_ISREG(before.st_mode) and before.st_uid==os.geteuid() and before.st_nlink==1
        assert before.st_size<=1048576 and before.st_mode&0o077==0
        raw=bytearray()
        while True:
            block=os.read(descriptor,min(65536,1048577-len(raw)))
            if not block: break
            raw.extend(block); assert len(raw)<=1048576
        after=os.fstat(descriptor); final=path.lstat()
        identity=lambda x:(x.st_dev,x.st_ino,x.st_size,x.st_mtime_ns,x.st_ctime_ns)
        assert identity(before)==identity(after)==identity(final) and len(raw)==before.st_size
    finally: os.close(descriptor)
    total+=len(raw); assert total<=8*1048576 and len(files)<32
    files[str(path.relative_to(run))]=dict(bytes=len(raw),sha256=hashlib.sha256(raw).hexdigest(),base64=base64.b64encode(raw).decode())
assert names==sorted(run.rglob('*'))
print(json.dumps(dict(files=files,processes=observe_processes(time.monotonic()+3),
    journal=observe_journal(device_directory()),nativeLaunched=False)),flush=True)
