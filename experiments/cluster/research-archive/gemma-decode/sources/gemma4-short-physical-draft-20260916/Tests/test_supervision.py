"""Prospective CPU-only controls. No native executable, model or SSH is used."""
import fcntl
import hashlib
import io
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch
BASE=Path(__file__).resolve().parents[1]
sys.path[:0]=[str(BASE/'package'),str(BASE)]
from native_gate import acquire
from gemma_inputs import job_for, REMOTE
from target_processes import parse_processes
from worker_contract import WorkerSpec
from worker_processes import PipeWorkers
from receive_collection import receive
from binding_common import canonical
from gemma_result import result as native_result


class Checks(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name).resolve()
        self.device=self.root/'device';self.device.mkdir(mode=0o700)
        self.journal=self.device/'native-device.lease';self.journal.touch(mode=0o600)
    def tearDown(self):self.temp.cleanup()
    def test_empty_gate_keeps_same_inode(self):
        before=self.journal.stat();fd,row=acquire(self.device)
        try:
            self.assertFalse(os.get_inheritable(fd));self.assertEqual(row['fileInode'],before.st_ino)
            with self.journal.open('rb') as other:
                with self.assertRaises(BlockingIOError):fcntl.flock(other.fileno(),fcntl.LOCK_EX|fcntl.LOCK_NB)
        finally:os.close(fd)
        self.assertEqual(self.journal.read_bytes(),b'');self.assertEqual(self.journal.stat().st_ino,before.st_ino)
    def test_existing_lock_refuses(self):
        with self.journal.open('rb') as owner:
            fcntl.flock(owner.fileno(),fcntl.LOCK_EX|fcntl.LOCK_NB)
            with self.assertRaises(BlockingIOError):acquire(self.device)
    def test_canonical_replacement_during_lock_refuses(self):
        original=fcntl.flock
        def replace(fd,operation):
            original(fd,operation);self.journal.unlink();self.journal.write_bytes(b'changed');self.journal.chmod(0o600)
        with patch('native_gate.fcntl.flock',replace):
            with self.assertRaises(ValueError):acquire(self.device)
        self.assertEqual(self.journal.read_bytes(),b'changed')
    def test_nonempty_journal_never_cleared(self):
        self.journal.write_bytes(b'{"owner":"unresolved"}\n')
        before=self.journal.read_bytes()
        with self.assertRaises(ValueError):acquire(self.device)
        self.assertEqual(self.journal.read_bytes(),before)
    def test_link_mode_and_hardlink_refused(self):
        self.journal.chmod(0o644)
        with self.assertRaises(ValueError):acquire(self.device)
        self.journal.chmod(0o600);os.link(self.journal,self.root/'second')
        with self.assertRaises(ValueError):acquire(self.device)
        (self.root/'second').unlink();self.journal.unlink();self.journal.symlink_to(self.root/'missing')
        with self.assertRaises(OSError):acquire(self.device)
    def test_same_pid_exec_retains_gate_until_exit(self):
        second="import os,sys;print(str(os.getpid())+':'+str(os.fstat(int(sys.argv[1])).st_ino),flush=True);sys.stdin.readline()"
        first=("import os,sys;from pathlib import Path;sys.path.insert(0,sys.argv[1]);from native_gate import acquire;"
               "fd,_=acquire(Path(sys.argv[2]));os.set_inheritable(fd,True);os.execv(sys.executable,[sys.executable,'-c',sys.argv[3],str(fd)])")
        child=subprocess.Popen([sys.executable,'-B','-c',first,str(BASE/'package'),str(self.device),second],
            stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
        try:
            self.assertTrue(select.select([child.stdout],[],[],3)[0]);line=child.stdout.readline().decode().strip()
            self.assertEqual(line,f'{child.pid}:{self.journal.stat().st_ino}')
            with self.assertRaises(BlockingIOError):acquire(self.device)
            _,err=child.communicate(b'done\n',timeout=3);self.assertEqual(child.returncode,0);self.assertEqual(err,b'')
        finally:
            if child.returncode is None:os.killpg(child.pid,signal.SIGKILL);child.wait(timeout=3)
            for stream in (child.stdin,child.stdout,child.stderr):
                if stream is not None:stream.close()
        fd,_=acquire(self.device);os.close(fd)
    def test_gemma_and_old_native_names_observed(self):
        result=parse_processes(b'0 0 kernel_task\n100 501 /a/GemmaShortCorrectnessCheck\n101 501 /a/cluster-inference\n102 501 /usr/bin/python3\n')
        self.assertEqual([x['pid'] for x in result['prohibited']],[100,101])
    def test_job_attempt_is_bounded_and_role_only(self):
        base=dict(mode='full',outputDirectory='old',requestID='same')
        self.assertEqual(job_for(base,'stage0',2),dict(mode='stage0',outputDirectory=str(REMOTE/'runs/stage0-2/sidecars'),requestID='same'))
        for mode,attempt in [('other',1),('full',0),('full',10),('full',True)]:
            with self.assertRaises(ValueError):job_for(base,mode,attempt)
    def test_pipe_record_has_no_lf_but_disk_keeps_it(self):
        expected={'scopeSHA256':'1'*64}
        value=dict(schema='gemma4_short_result_v1',mode='full',expected=expected,modelReleased=True,nativeExecuted=True,
            physicalProcessOrLeaseRetirementEstablished=False,runtimeServingEnabled=False,numericalComparisonPerformed=False,
            throughputMeasurementValid=False,encryptedRDMAEstablished=False,collectiveCreated=False,collectiveReleased=False,
            nativeCacheBytesAfterRelease=0,execution=dict(committedTokens=33,finishReason='length',requestStateRetired=True,selectedTokenIDs=[1,2]))
        raw=canonical(value);self.assertEqual(native_result(raw,'full',expected)['selectedTokenIDs'],[1,2])
        with self.assertRaises(ValueError):native_result(raw+b'\n','full',expected)
        with self.assertRaises(ValueError):native_result(raw,'stage0',expected)
    def test_absolute_watchdog_covers_after_report(self):
        spec=WorkerSpec((sys.executable,'-B','-c',"import sys,time;print('{}',flush=True);time.sleep(20)"),dict(PATH='/usr/bin:/bin'),'solo',None)
        pipes=PipeWorkers((spec,),self.root/'pipes',1,lambda _:None)
        try:
            pipes.start();self.assertEqual(pipes.collect('report',lambda _,raw:json.loads(raw)),[{}])
            with self.assertRaises((TimeoutError,ValueError)):pipes.finish()
        finally:pipes.close(kill=True)
        self.assertTrue(pipes.expired.is_set());self.assertTrue(all(p.returncode is not None for p in pipes.children))
    def test_output_prefix_bound_refuses(self):
        spec=WorkerSpec((sys.executable,'-B','-c',"import sys;sys.stdout.write('x'*1048578);sys.stdout.flush()"),dict(PATH='/usr/bin:/bin'),'solo',None)
        pipes=PipeWorkers((spec,),self.root/'oversize',3,lambda _:None)
        try:
            pipes.start()
            with self.assertRaises(ValueError):pipes.collect('report',lambda _,raw:raw)
        finally:pipes.close(kill=True)
        self.assertLessEqual(pipes.total_output,2*1024**2)
    def archive(self,declared,actual):
        path=self.root/'archive';header=dict(schema='gemma_short_collection_v1',mode='full',attempt=1,files=declared)
        with path.open('wb') as out:
            out.write(canonical(header)+b'\n')
            with tarfile.open(fileobj=out,mode='w|') as archive:
                for name,raw in actual:
                    info=tarfile.TarInfo(name);info.size=len(raw);archive.addfile(info,io.BytesIO(raw))
        return path
    def test_collection_exact_bytes(self):
        raw=b'{}\n';rows=[dict(path='terminal.json',bytes=len(raw),sha256=hashlib.sha256(raw).hexdigest())]
        receive(self.archive(rows,[('terminal.json',raw)]),self.root/'returned')
        self.assertEqual((self.root/'returned/terminal.json').read_bytes(),raw)
    def test_collection_missing_and_extra_refused(self):
        rows=[dict(path='terminal.json',bytes=3,sha256=hashlib.sha256(b'{}\n').hexdigest())]
        with self.assertRaises(ValueError):receive(self.archive(rows,[]),self.root/'missing')
        (self.root/'archive').unlink()
        with self.assertRaises(ValueError):receive(self.archive(rows,[('extra',b'x')]),self.root/'extra')
    def test_collection_traversal_and_bad_hash_refused(self):
        rows=[dict(path='../escape',bytes=1,sha256=hashlib.sha256(b'x').hexdigest())]
        with self.assertRaises(ValueError):receive(self.archive(rows,[('../escape',b'x')]),self.root/'badpath')
        (self.root/'archive').unlink();rows=[dict(path='terminal.json',bytes=1,sha256='0'*64)]
        with self.assertRaises(ValueError):receive(self.archive(rows,[('terminal.json',b'x')]),self.root/'badhash')


if __name__=='__main__':unittest.main()
