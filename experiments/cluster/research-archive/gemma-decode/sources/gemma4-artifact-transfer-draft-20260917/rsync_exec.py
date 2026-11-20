"""Lease-holding guard; rsync stays in the watchdog-owned process group."""
import os
from pathlib import Path
import re
import subprocess
import sys
import time
from artifact import BASE,PREPARATION,STAGE,record,disk
from binding_common import require,same
from lease_gate import acquire
from mtp_journal import device_directory
from target_processes import observe
from source_guard import check_sources

def main():
    args=sys.argv[1:]
    require(BASE==PREPARATION and BASE.resolve()==BASE,'Exact receiver installation')
    pins=check_sources()
    require(len(args)>=4 and args[0]=='--server' and args[-2]=='.' and args[-1].rstrip('/')==str(STAGE),'Exact receiver destination/role')
    # Only rsync server switches emitted by the fixed -rt/partial/files-from
    # client are accepted. No option may introduce another filesystem path.
    long={'--server','--stats','--partial','--timeout=60','--files-from=-','--from0','--no-implied-dirs'}
    for value in args[:-2]:
        require(value in long or (value.startswith('-') and not value.startswith('--') and re.fullmatch(r'-[A-Za-z.]+',value)), 'Unexpected rsync server option')
    require('--sender' not in args and '--daemon' not in args,'Receiver only')
    fd,gate=acquire(device_directory())
    child=None
    try:
        processes=observe(time.monotonic()+4);require(not processes['prohibited'],'Native/owner is already live')
        gate.update(processObservation=processes,disk=disk(STAGE.parent),rsyncArgv=['/usr/bin/rsync']+args,
                    receiverDeadlineSeconds=880,sourcePinsSHA256=pins,watchdogDeadlineSeconds=890,inheritedAcrossExec=False)
        record(PREPARATION/'receiver-gate.json',gate)
        # Keep the FD here: rsync's descriptor cleanup cannot release the gate.
        # Do not start another group. The outer owned handle fences this guard,
        # rsync, and its descendants together even if the SSH stream disappears.
        child=subprocess.Popen(['/usr/bin/rsync']+args)
        code=child.wait(timeout=880);require(code==0,'Actual receiver failed: '+str(code))
    finally:
        if child is not None and child.returncode is None:
            child.kill();child.wait(timeout=5)
        os.close(fd)
if __name__=='__main__':main()
