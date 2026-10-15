"""Actual guard/child/descendant failures; private files, no rsync or SSH."""
import contextlib
import fcntl
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from owned_process import invoke_controller
import rsync_exec

HERE=Path(__file__).resolve()
def child_mode():
    mode,variant,directory=sys.argv[1:];root=Path(directory)
    signal.alarm(8) # Failed fixtures cannot leave indefinite descendants.
    if mode=='_descendant':
        (root/'descendant.tmp').write_text(json.dumps({'pid':os.getpid(),'pgid':os.getpgrp()}));os.replace(root/'descendant.tmp',root/'descendant.json')
        time.sleep(30)
    elif mode=='_tree':
        child=subprocess.Popen(['/usr/bin/python3','-B',str(HERE),'_descendant',variant,str(root)])
        (root/'tree.json').write_text(json.dumps({'pid':os.getpid(),'pgid':os.getpgrp(),'descendantPID':child.pid}))
        deadline=time.monotonic()+2
        while not (root/'descendant.json').exists() and time.monotonic()<deadline:time.sleep(.01)
        if variant=='nonzero':sys.exit(3)
        time.sleep(30)
    elif mode=='_guard':
        fd=os.open(root/'lease',os.O_RDONLY|os.O_NOFOLLOW);fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
        (root/'guard.json').write_text(json.dumps({'pid':os.getpid(),'pgid':os.getpgrp(),'leaseInode':os.fstat(fd).st_ino}))
        if variant=='interrupted_spawn':
            original=rsync_exec.subprocess.Popen
            def interrupted(command):
                original(command) # Real child exists; caller receives no handle.
                deadline=time.monotonic()+2
                while not (root/'descendant.json').exists() and time.monotonic()<deadline:time.sleep(.01)
                raise KeyboardInterrupt('Injected after actual spawn, before return')
            rsync_exec.subprocess.Popen=interrupted
        rsync_exec.run_receiver(['/usr/bin/python3','-B',str(HERE),'_tree',variant,str(root)],timeout=.7)
        raise AssertionError('Failure case returned normally')
    else:raise ValueError('Unknown fixture mode')

class OwnedGroupTests(unittest.TestCase):
    def check_case(self,variant):
        with tempfile.TemporaryDirectory(dir='/private/tmp') as temp:
            root=Path(temp);lease=root/'lease';lease.write_bytes(b'');lease.chmod(0o600);inode=lease.stat().st_ino
            receipt={};started=time.monotonic()
            with (root/'out').open('xb') as out,(root/'err').open('xb') as err,contextlib.redirect_stdout(io.StringIO()):
                invoke_controller(['/usr/bin/python3','-B',str(HERE),'_guard',variant,str(root)],out,err,receipt,timeout=12)
            # Only observe after reaping. Even a broken candidate gets no signal
            # based on a stale PGID; its small children have their own 8s alarms.
            absent=False;deadline=started+10
            while time.monotonic()<deadline:
                try:os.killpg(receipt['pid'],0)
                except ProcessLookupError:absent=True;break
                time.sleep(.01)
            elapsed=time.monotonic()-started
            self.assertTrue(absent,'Fixture descendants did not retire')
            self.assertEqual(receipt['exitCode'],-signal.SIGKILL);self.assertTrue(receipt['reaped'])
            self.assertFalse(receipt['killedOwnedGroup'],'Outer timeout must not provide the tested cleanup')
            self.assertLess(elapsed,3,'Retirement must precede fixture self-expiry')
            guard=json.loads((root/'guard.json').read_text());tree=json.loads((root/'tree.json').read_text());descendant=json.loads((root/'descendant.json').read_text())
            self.assertEqual({guard['pgid'],tree['pgid'],descendant['pgid']},{receipt['pid']})
            self.assertEqual(guard['pid'],receipt['pid']);self.assertEqual(tree['descendantPID'],descendant['pid'])
            fd=os.open(lease,os.O_RDONLY|os.O_NOFOLLOW)
            try:
                fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB);self.assertEqual(os.fstat(fd).st_ino,inode);self.assertEqual(os.pread(fd,1,0),b'')
            finally:os.close(fd)
            print(json.dumps(dict(case=variant,guardPID=guard['pid'],receiverPID=tree['pid'],descendantPID=descendant['pid'],exitCode=receipt['exitCode'],elapsedSeconds=elapsed,reaped=True,groupAbsent=True,sameEmptyGate=True)),flush=True)
    def test_timeout_descendants(self):self.check_case('timeout')
    def test_nonzero_after_descendant_spawn(self):self.check_case('nonzero')
    def test_interrupted_spawn_before_handle(self):self.check_case('interrupted_spawn')

if __name__=='__main__':
    if len(sys.argv)>1 and sys.argv[1].startswith('_'):child_mode()
    else:unittest.main()
