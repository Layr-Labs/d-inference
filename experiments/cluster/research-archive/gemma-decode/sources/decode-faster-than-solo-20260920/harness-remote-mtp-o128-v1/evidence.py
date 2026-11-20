"""Bounded retained physical evidence checks, independent of model numerics."""
import hashlib
import os
from pathlib import Path
import re
import stat
from decimal import Decimal
import sys

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT/'package'))
from binding_common import parse, require
from reference_resources import validate_local

EMPTY = hashlib.sha256(b'').hexdigest()
JOURNAL = ('path','directoryDevice','directoryInode','fileDevice','fileInode')


class Inputs:
    def __init__(self): self.saved = []

    def raw(self, path, maximum=2*1024**2, keep=True):
        path = Path(path)
        require(path.parent.resolve() == path.parent, 'Retained parent is not canonical')
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
        with os.fdopen(fd,'rb') as f:
            before=os.fstat(f.fileno())
            require(stat.S_ISREG(before.st_mode) and before.st_nlink==1
                and 0<=before.st_size<=maximum,'Retained file bound/type differs')
            digest=hashlib.sha256();parts=[];size=0
            for block in iter(lambda:f.read(1024**2),b''):
                size+=len(block);require(size<=maximum,'Retained file grew')
                digest.update(block)
                if keep:parts.append(block)
            after=os.fstat(f.fileno())
        stamp=lambda s:(s.st_dev,s.st_ino,s.st_mode,s.st_size,s.st_mtime_ns,s.st_ctime_ns)
        require(stamp(before)==stamp(after) and size==before.st_size,'Retained file changed')
        pin=dict(path=str(path),sha256=digest.hexdigest(),bytes=size)
        self.saved.append((path,maximum,stamp(before),pin))
        return b''.join(parts) if keep else pin

    def read(self,path,maximum=2*1024**2): return parse(self.raw(path,maximum))
    def pin(self,path,maximum=2*1024**2): return self.raw(path,maximum,False)
    def recheck(self):
        for path,maximum,stamp,pin in list(self.saved):
            other=Inputs();require(other.pin(path,maximum)==pin and other.saved[-1][2]==stamp,'Input changed during review')


def journal(value, initial=None):
    require(set(value)==set(JOURNAL)|{'bytes','sha256','exclusiveObservationLockAcquired','journalMutationPerformed'},'Journal schema')
    require(value['path']=='/Users/developer/.darkbloom/cluster-device/native-device.lease'
        and type(value['bytes']) is int and value['bytes']==0 and value['sha256']==EMPTY
        and value['exclusiveObservationLockAcquired'] is True and value['journalMutationPerformed'] is False,'Journal not empty')
    for key in JOURNAL[1:]:require(type(value[key]) is int and value[key]>0,'Journal inode missing')
    if initial is not None:require(all(value[k]==initial[k] for k in JOURNAL),'Journal inode changed')


def processes(value):
    require(set(value)=={'command','observedStartMonotonicNS','observedEndMonotonicNS',
        'observerPID','processCount','prohibited','stdoutSHA256'},'Process schema')
    require(value['command']==['/bin/ps','-Aww','-o','pid=,uid=,comm='] and value['prohibited']==[]
        and type(value['observerPID']) is int and value['observerPID']>0
        and type(value['processCount']) is int and value['processCount']>0,'Process absence missing')
    a,b=value['observedStartMonotonicNS'],value['observedEndMonotonicNS']
    require(type(a) is int and type(b) is int and 0<=a<=b<=a+4*10**9,'Process observation clock')
    require(re.fullmatch('[0-9a-f]{64}',value['stdoutSHA256']) is not None,'Process raw digest')


def resources(raw):
    rows=[parse(line) for line in raw.splitlines()]
    require(2<=len(rows)<=2000 and rows[0]['phase']=='prelaunch' and rows[-1]['phase']=='postflight'
        and sum(x['phase']=='prelaunch' for x in rows)==1 and sum(x['phase']=='postflight' for x in rows)==1,'Resource anchors')
    previous=0
    for value in rows:
        require(set(value)=={'phase','startedMonotonicNS','completedMonotonicNS','timestampUTC','actualFreeBytes',
            'pressureLevel','reportedSwapBytes','acPower','rawVMStat','rawMemory','rawPower'},'Resource schema')
        page=re.search(r'page size of (\d+) bytes',value['rawVMStat'])
        free=re.search(r'Pages free:\s+(\d+)\.',value['rawVMStat'])
        swap=re.search(r'used\s*=\s*([0-9.]+)([MG])',value['rawMemory'])
        require(page and free and swap,'Missing raw resource values')
        require(value['actualFreeBytes']==int(page[1])*int(free[1])
            and value['pressureLevel']==int(value['rawMemory'].splitlines()[0])
            and Decimal(value['reportedSwapBytes'])==Decimal(swap[1])*(1024**2 if swap[2]=='M' else 1024**3)
            and value['acPower']==("Now drawing from 'AC Power'" in value['rawPower']),'Resource raw replay differs')
        validate_local(value)
        require(previous<=value['startedMonotonicNS'],'Resource clock reversed')
        previous=value['completedMonotonicNS']
    require(rows[-1]['completedMonotonicNS']-rows[0]['startedMonotonicNS']<315*10**9,'Physical resource interval exceeded')
    return dict(observations=len(rows),minimumActualFreeBytes=min(x['actualFreeBytes'] for x in rows),
                pressureLevel=1,swapBytes=0,acPower=True,rawReplayPassed=True)


def action(inputs, name, expected, source_sha, activation_sha):
    directory=ROOT/'root-actions'/name
    record=inputs.read(directory/'receipt.json')
    require(record['schema']=='gemma4_remote_mtp_root_action_v1' and record['action']==expected
        and record['status']=='passed' and record['exitCode']==0 and record['reaped'] is True
        and record['groupAbsent'] is True and record['killedOwnedGroup'] is False
        and record['sourceManifestSHA256']==source_sha and record['activationSHA256']==activation_sha,'Root action did not complete')
    for stream in ('stdout','stderr'):
        pin=inputs.pin(directory/stream,32*1024**2)
        require(pin['sha256']==record[stream+'SHA256'] and pin['bytes']==record[stream+'Bytes'],'Root output identity differs')
    require(record['stderrBytes']==0,'Root action stderr is not empty')
    return record
