"""Own only this rsync receiver group; protocol bytes remain on stdin/stdout."""
import contextlib
import io
import os
import signal
import sys
import time
from artifact import BASE,PREPARATION,record
from binding_common import require
from owned_process import invoke_controller
from source_guard import check_sources

class LaunchReceipt(dict):
    def update(self,*args,**kwargs):
        super().update(*args,**kwargs)
        if 'pid' in self and not (PREPARATION/'receiver-launched.json').exists():
            # The inherited helper publishes before its wait/cleanup try block.
            # A receipt I/O failure must not escape with a live owned child.
            try:record(PREPARATION/'receiver-launched.json',dict(self,supervisorPID=os.getpid(),startedUnix=time.time()))
            except BaseException as error:self['launchReceiptError']=type(error).__name__+': '+str(error)[:1024]

def main():
    require(BASE==PREPARATION and BASE.resolve()==BASE,'Exact receiver root')
    pins=check_sources()
    # Detach the watchdog from the SSH session. A dropped SSH connection cannot
    # remove its absolute child fence; protocol EOF or the deadline ends rsync.
    if os.getsid(0)!=os.getpid():os.setsid()
    receipt=LaunchReceipt(status='started',startedMonotonic=time.monotonic(),argv=sys.argv[1:],sourcePinsSHA256=pins,watchdogSession=os.getsid(0))
    original={n:signal.getsignal(n) for n in (signal.SIGHUP,signal.SIGINT,signal.SIGTERM)}
    def interrupted(n,_):raise SystemExit(128+n)
    for n in original:signal.signal(n,interrupted)
    output,error=sys.stdout.buffer,sys.stderr.buffer
    try:
        with contextlib.redirect_stdout(io.StringIO()) as observed:
            invoke_controller(['/usr/bin/python3','-B',str(PREPARATION/'rsync_exec.py')]+sys.argv[1:],output,error,receipt,timeout=890)
        receipt['launchObservation']=observed.getvalue()
        require('launchReceiptError' not in receipt,'Receiver launch receipt failed')
        require(receipt.get('exitCode')==0 and receipt.get('reaped') and receipt.get('groupAbsent'),'Receiver did not retire cleanly')
        require(check_sources()==pins,'Receiver source postflight')
        receipt['status']='passed'
    except BaseException as exc:receipt['status']='failed';receipt['failure']=type(exc).__name__+': '+str(exc)[:2048];raise
    finally:
        receipt['elapsedSeconds']=time.monotonic()-receipt['startedMonotonic'];record(PREPARATION/'receiver-terminal.json',receipt)
        for n,handler in original.items():signal.signal(n,handler)
if __name__=='__main__':main()
