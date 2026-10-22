"""Source-bound startup retry and remote/local stream-boundary regressions."""
import copy
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import unittest

from jaccl_stderr import RETRY_LINES,RetryDiagnostics,validate_retry_bytes
from physical_common import write_json
from rank_validation import RankValidator
from run_physical import Capture,validate_completed_streams
from test_physical import setup
from worker_adapter import ResidentWorkerCohort
from worker_contract import WorkerSpec,encoded,run_command

HERE=Path(__file__).parent


class RetryTests(unittest.TestCase):
    def test_actual_fragmented_line_and_exact_four_attempt_bound(self):
        actual=b'[jaccl] Connection attempt 0 waiting 1000 ms\n'
        self.assertEqual(len(actual),45)
        self.assertEqual(hashlib.sha256(actual).hexdigest(),'f919fe10e6c53df9cc31bff522c1b61eb3e9853d9ea5fff80cc870cb1bc6ebca')
        policy=RetryDiagnostics(1)
        for byte in actual:policy.feed(bytes((byte,)))
        self.assertEqual(policy.count,1)
        for line in RETRY_LINES[1:]:policy.feed(line)
        self.assertEqual(len(policy.raw),180)
        policy.seal();self.assertTrue(policy.summary()['bootstrapSealed'])
        with self.assertRaises(ValueError):policy.feed(actual)
        self.assertEqual(validate_retry_bytes(0,b'')['lineCount'],0)

    def test_unknown_partial_duplicate_out_of_order_and_wrong_rank(self):
        for rank,raw in [(0,RETRY_LINES[0]),(1,RETRY_LINES[1]),(1,RETRY_LINES[0]*2),
                         (1,RETRY_LINES[0]+b'x'),(1,RETRY_LINES[0].replace(b'1000',b'1001')),
                         (1,RETRY_LINES[0][:-1]),(1,b''.join(RETRY_LINES)+RETRY_LINES[0])]:
            with self.subTest(rank=rank,raw=raw),self.assertRaises(ValueError):validate_retry_bytes(rank,raw)
        policy=RetryDiagnostics(1);policy.seal()
        with self.assertRaisesRegex(ValueError,'outside'):policy.feed(RETRY_LINES[0])

    def test_retry_native_stderr_stays_remote_and_four_barriers_complete(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);plan,jobs,runs=setup(root)
            for job in jobs:Path(job['peer']['run_dir']).mkdir()
            jobfile=root/'jobs.json';write_json(jobfile,jobs)
            output=root/'client';output.mkdir();capture=Capture(output)
            validator=RankValidator(jobs,lambda r:json.loads((Path(jobs[r]['peer']['run_dir'])/'owner.json').read_bytes()),capture)
            specs=[WorkerSpec((sys.executable,'-B',str(HERE/'fabricated_remote.py'),str(jobfile),str(rank),
                'retry' if rank==1 else 'success'),dict(PATH='/usr/bin:/bin',PYTHONDONTWRITEBYTECODE='1'),'rank',rank) for rank in (0,1)]
            cohort=ResidentWorkerCohort(specs,plan['cohort_id'],jobs[0]['opened']['requests'],output/'pipes',15,
                lambda phase:None,validator.identity,validator.numerical)
            with cohort:
                for request in runs:cohort.run(request)
            self.assertEqual(validator.stopped,[True,True])
            for rank in (0,1):
                remote=Path(jobs[rank]['peer']['run_dir']);terminal=json.loads((remote/'terminal.json').read_bytes())
                self.assertEqual(terminal['status'],'completed');self.assertTrue(terminal['ownedGroupFenceComplete'])
                shutil.copytree(remote/'native',output/('remote-rank-%d'%rank)/'native')
                validate_completed_streams(output,rank,terminal)
                self.assertEqual((output/('pipes/worker-%d.stderr'%rank)).read_bytes(),b'')
                self.assertEqual((remote/'native/worker-0.stderr').read_bytes(),RETRY_LINES[0] if rank else b'')
                changed=copy.deepcopy(terminal);changed['bootstrapDiagnostics']['lineCount']+=1
                with self.assertRaises(ValueError):validate_completed_streams(output,rank,changed)
            (output/'pipes/worker-1.stderr').write_bytes(RETRY_LINES[0])
            with self.assertRaisesRegex(ValueError,'SSH stderr'):validate_completed_streams(output,1,terminal)

    def test_supervisor_rejects_partial_unknown_late_and_rank0_diagnostics(self):
        for rank,scenario in [(1,'retry_partial'),(1,'retry_unknown'),(1,'retry_late'),(0,'retry')]:
            with self.subTest(rank=rank,scenario=scenario),tempfile.TemporaryDirectory() as directory:
                root=Path(directory);plan,jobs,runs=setup(root)
                run=Path(jobs[rank]['peer']['run_dir']);run.mkdir();jobfile=root/'jobs.json';write_json(jobfile,jobs)
                process=subprocess.Popen([sys.executable,'-B',str(HERE/'fabricated_remote.py'),str(jobfile),str(rank),scenario],
                    stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,bufsize=0,start_new_session=True)
                try:
                    process.stdin.write(encoded(jobs[rank]['opened']));process.stdin.flush()
                    if scenario=='retry_late':
                        self.assertTrue(process.stdout.readline())
                        process.stdin.write(encoded(run_command(jobs[rank]['opened'],0,runs[0])));process.stdin.flush()
                    process.wait(timeout=5)
                    terminal=json.loads((run/'terminal.json').read_bytes())
                    self.assertEqual(terminal['status'],'failed');self.assertEqual(terminal['completedRequests'],0)
                    self.assertTrue(terminal['nativeLeaderReaped']);self.assertTrue(terminal['ownedGroupFenceComplete'])
                    self.assertTrue((run/'native/worker-0.stderr').read_bytes())
                finally:
                    if process.poll() is None:os.killpg(process.pid,signal.SIGKILL);process.wait(timeout=2)
                    for stream in (process.stdin,process.stdout,process.stderr):stream.close()


if __name__=='__main__':unittest.main()
