"""Lease-holding guard; rsync stays in the watchdog-owned process group."""
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time
from artifact import BASE,PREPARATION,STAGE,record,disk
from binding_common import require,same
from lease_gate import acquire
from mtp_journal import device_directory
from target_processes import observe
from source_guard import check_sources

def run_receiver(command,timeout=880):
    # The live guard itself keeps this group identity from being reused, even
    # when wait() has already reaped rsync but a descendant remains.
    group=os.getpid();same(os.getpgrp(),group,'Receiver must lead its owned group')
    child=None
    try:
        child=subprocess.Popen(command)
        code=child.wait(timeout=timeout);require(code==0,'Actual receiver failed: '+str(code))
    except BaseException:
        # Popen may spawn before an interruption prevents assignment. The live
        # guard owns this group regardless of whether its child handle arrived.
        same(os.getpgrp(),group,'Live receiver group changed')
        os.killpg(group,signal.SIGKILL)
        raise

def main():
    args=sys.argv[1:]
    require(BASE==PREPARATION and BASE.resolve()==BASE,'Exact receiver installation')
    pins=check_sources()
    require(len(args)>=4 and args[0]=='--server' and args[-2]=='.' and args[-1].rstrip('/')==str(STAGE),'Exact receiver destination/role')
    # Only rsync server switches emitted by the fixed -rt/partial/files-from
    # client are accepted. No option may introduce another filesystem path.
    long={'--server','--stats','--partial','--timeout=60','--files-from=-','--from0','--no-implied-dirs','--relative','--dirs'}
    for value in args[:-2]:
        require(value in long or (value.startswith('-') and not value.startswith('--') and re.fullmatch(r'-[A-Za-z.]+',value)), 'Unexpected rsync server option')
    require('--sender' not in args and '--daemon' not in args,'Receiver only')
    same(os.getpgrp(),os.getpid(),'Receiver guard group leader')
    fd,gate=acquire(device_directory())
    try:
        processes=observe(time.monotonic()+4);require(not processes['prohibited'],'Native/owner is already live')
        gate.update(processObservation=processes,disk=disk(STAGE.parent),rsyncArgv=['/usr/bin/rsync']+args,
                    receiverDeadlineSeconds=880,sourcePinsSHA256=pins,watchdogDeadlineSeconds=890,inheritedAcrossExec=False)
        record(PREPARATION/'receiver-gate.json',gate)
        # Keep the FD here: rsync's descriptor cleanup cannot release the gate.
        # Do not start another group. The outer owned handle fences this guard,
        # rsync, and its descendants together even if the SSH stream disappears.
        run_receiver(['/usr/bin/rsync']+args)
    finally:os.close(fd)
if __name__=='__main__':main()
