"""Read-only bounded process/journal observation or complete run archive."""
import argparse
import hashlib
import os
from pathlib import Path
import stat
import sys
import tarfile
import time
REMOTE=Path('/Users/developer/DarkbloomDev/gemma4-short-identity-corrected-20260917')
sys.path.insert(0,str(REMOTE))
from binding_common import canonical, require
from binding_inputs import snapshot
from mtp_journal import device_directory, observe as journal, require_empty
from target_processes import observe as processes


def observation():
    value=processes(time.monotonic()+4)
    result=dict(active=value['prohibited'],processes=value,journalBytes=1,journalLockObserved=False)
    try:
        lease=journal(device_directory());result.update(journal=lease,journalBytes=lease['bytes'],journalLockObserved=True)
    except Exception as error:result['journalError']=type(error).__name__+': '+str(error)[:1024]
    return result


def main():
    p=argparse.ArgumentParser(allow_abbrev=False);p.add_argument('action',choices=['observe','collect'])
    p.add_argument('--mode',choices=['full','stage0','stage1']);p.add_argument('--attempt',type=int,default=1);a=p.parse_args()
    value=observation()
    if a.action=='observe':print(canonical(value).decode(),flush=True);return
    require(a.mode is not None and 1<=a.attempt<=9,'Collection role/attempt')
    require(not value['active'] and value['journalLockObserved'],'Live or uncertain native owner')
    require_empty(value['journal']);root=REMOTE/'runs'/f'{a.mode}-{a.attempt}'
    require(root.resolve()==root and root.is_dir(),'Canonical run required')
    rows=[];total=0
    for directory,dirs,files in os.walk(root,followlinks=False):
        for name in dirs:
            s=(Path(directory)/name).lstat();require(stat.S_ISDIR(s.st_mode) and s.st_uid==os.geteuid() and s.st_mode&0o077==0,'Unsafe evidence directory')
        for name in files:
            path=Path(directory)/name;s=path.lstat();relative=path.relative_to(root).as_posix()
            require(stat.S_ISREG(s.st_mode) and s.st_nlink==1 and s.st_uid==os.geteuid() and s.st_mode&0o077==0,'Unsafe evidence file')
            require(relative.count('/')<=1 and s.st_size<=16*1024**2,'Evidence member bound')
            item=snapshot(path,max(1,s.st_size),keep=False,empty=True);total+=item['size_bytes']
            require(total<=64*1024**2 and len(rows)<160,'Total evidence bound')
            rows.append(dict(path=relative,bytes=item['size_bytes'],sha256=item['sha256'],identity=item['identity']))
    require(any(r['path']=='terminal.json' for r in rows),'No retained terminal')
    header=dict(schema='gemma_short_collection_v1',mode=a.mode,attempt=a.attempt,remoteRoot=str(root),observation=value,
        files=[{k:r[k] for k in ('path','bytes','sha256')} for r in sorted(rows,key=lambda r:r['path'])])
    raw=canonical(header)+b'\n';require(len(raw)<=131072,'Archive header bound');sys.stdout.buffer.write(raw)
    with tarfile.open(fileobj=sys.stdout.buffer,mode='w|') as archive:
        for row in sorted(rows,key=lambda r:r['path']):
            path=root/row['path'];fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_CLOEXEC)
            with os.fdopen(fd,'rb') as stream:
                s=os.fstat(stream.fileno());stamp=lambda x:(x.st_dev,x.st_ino,x.st_mode,x.st_size,x.st_mtime_ns,x.st_ctime_ns)
                require(stamp(s)==tuple(row['identity']),'Evidence changed before archive')
                info=tarfile.TarInfo(row['path']);info.size=row['bytes'];info.mode=0o600;info.mtime=0
                archive.addfile(info,stream)
                require(stamp(os.fstat(stream.fileno()))==stamp(path.lstat())==stamp(s),'Evidence changed during archive')


if __name__=='__main__':main()
