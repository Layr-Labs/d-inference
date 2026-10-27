"""Read-only receiver status, or full verification then no-replace promotion."""
import argparse
import ctypes
import json
import os
import signal
import time
from artifact import BASE,PREPARATION,STAGE,FINAL,verify_tree,recheck,record,disk,digest,inspect
from binding_common import require,same
from lease_gate import acquire
from mtp_journal import device_directory,observe as journal,require_empty
from target_processes import observe as processes
from source_guard import check_sources

def small(name):
    path=PREPARATION/name;before=inspect(path);require(before[4]<=65536,'Metadata bound')
    raw=path.read_bytes();same(inspect(path),before,'Metadata changed');return raw

def promote(source,destination):
    libc=ctypes.CDLL(None,use_errno=True);rename=libc.renamex_np
    rename.argtypes=[ctypes.c_char_p,ctypes.c_char_p,ctypes.c_uint];rename.restype=ctypes.c_int
    if rename(os.fsencode(source),os.fsencode(destination),0x00000004)!=0:raise OSError(ctypes.get_errno(),'renamex_np(RENAME_EXCL) refused')

def status():
    value=dict(receiverLaunched=(PREPARATION/'receiver-launched.json').exists(),groupAbsent=True,receiverTerminal=None)
    if value['receiverLaunched']:
        launched=json.loads(small('receiver-launched.json'));pid=launched['pid']
        require(type(pid) is int and pid>1,'Receiver PID observation')
        try:os.killpg(pid,0);value['groupAbsent']=False
        except ProcessLookupError:pass # Observation only; never signal a discovered PID.
        value['launched']=launched
    if (PREPARATION/'receiver-terminal.json').exists():
        raw=small('receiver-terminal.json');value['receiverTerminal']=json.loads(raw);value['receiverTerminalSHA256']=digest(raw)
    try:
        value['journal']=journal(device_directory());require_empty(value['journal'],json.loads(small('preparation.json'))['gate']);value['journalEmptyAndUnlocked']=True
    except Exception as error:value['journalEmptyAndUnlocked']=False;value['journalError']=type(error).__name__+': '+str(error)[:1024]
    return value

def main():
    p=argparse.ArgumentParser(allow_abbrev=False);p.add_argument('action',choices=['status','finalize']);a=p.parse_args()
    require(BASE==PREPARATION and BASE.resolve()==BASE,'Exact remote preparation root')
    pins=check_sources()
    if a.action=='status':print(json.dumps(status(),sort_keys=True));return
    started=time.monotonic();result=dict(status='started',modelExecuted=False,journalMutationPerformed=False,sourcePinsSHA256=pins);fd=None;failure=None
    def expired(*_):raise TimeoutError('Remote verification300s bound')
    old=signal.getsignal(signal.SIGALRM);signal.signal(signal.SIGALRM,expired);signal.alarm(300)
    try:
        state=status();require(state['receiverLaunched'] and state['groupAbsent'] and state['journalEmptyAndUnlocked'],'Receiver retirement unproven')
        terminal=state['receiverTerminal'];require(terminal and terminal['status']=='passed' and terminal['exitCode']==0 and terminal['reaped'] and terminal['groupAbsent'],'Successful owned receiver required')
        fd,gate=acquire(device_directory());result['gate']=gate
        require_empty(state['journal'],gate)
        for key in ('path','directoryDevice','directoryInode','fileDevice','fileInode'):
            same(json.loads(small('receiver-gate.json'))[key],gate[key],'Transfer/finalization gate identity')
        process=processes(time.monotonic()+4);require(not process['prohibited'],'A native/owner is live');result['processes']=process
        require(not os.path.lexists(FINAL) and FINAL.parent.resolve()==FINAL.parent,'Final model must be absent')
        result['disk']=disk(FINAL.parent);result['verification']=verify_tree(STAGE,started+300)
        recheck(STAGE,result['verification']);require(not os.path.lexists(FINAL),'Final path appeared during verification')
        # macOS RENAME_EXCL is an atomic non-overwrite operation, not a check+rename.
        promote(STAGE,FINAL)
        for parent in (PREPARATION,FINAL.parent):
            directory=os.open(parent,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW|os.O_CLOEXEC)
            try:os.fsync(directory)
            finally:os.close(directory)
        recheck(FINAL,result['verification']);result['finalDirectory']=str(FINAL);result['status']='passed'
        result['receiverTerminalSHA256']=digest(small('receiver-terminal.json'));same(result['receiverTerminalSHA256'],state['receiverTerminalSHA256'],'Receiver terminal unchanged')
        same(check_sources(),pins,'Finalizer source postflight')
    except BaseException as error:failure=error
    finally:
        if fd is not None:os.close(fd)
        signal.alarm(0);signal.signal(signal.SIGALRM,old);result['elapsedSeconds']=time.monotonic()-started
        try:
            result['postflight']=status();require(result['postflight']['journalEmptyAndUnlocked'],'Finalizer gate retirement')
            if 'gate' in result:require_empty(result['postflight']['journal'],result['gate'])
        except BaseException as error:
            result['postflightFailure']=type(error).__name__+': '+str(error)[:2048]
            if failure is None:failure=error
        if failure is not None:result['status']='failed';result['failure']=type(failure).__name__+': '+str(failure)[:2048]
        record(PREPARATION/'verification.json',result)
    if failure is not None:raise failure
    print(json.dumps(result,sort_keys=True))
if __name__=='__main__':main()
