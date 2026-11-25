"""Model-free cleanup ordering and actual owned local-child lifecycle checks."""
import ast
import io
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from parent_cleanup import invoke_controller, observe_retirement

class Clock:
    def __init__(self): self.now=0.0; self.sleeps=[]
    def __call__(self): return self.now
    def sleep(self, seconds): self.sleeps.append(seconds); self.now += seconds

def quiet(journal=0): return dict(active=[], journalBytes=journal, journalSHA256='e3b0', files={})

class RetirementChecks(unittest.TestCase):
    def test_both_hosts_retire_before_return_and_alias_release(self):
        clock=Clock(); events=[]
        def collect(rank, timeout):
            events.append(('observe', rank, clock.now))
            return dict(quiet(), active=['owned-native'] if clock.now < rank + 1 else [])
        result=observe_retirement(10,collect,lambda x:events.append(('retain',x['rank'],clock.now)),clock,clock.sleep)
        events.append(('release-alias',clock.now))
        self.assertEqual(clock.now,2);self.assertTrue(result['nativeProcessesAbsent']);self.assertTrue(result['journalsEmpty'])
        self.assertEqual(events[-1],('release-alias',2));self.assertEqual(result['samples'],3)
    def test_sticky_journal_never_becomes_success(self):
        clock=Clock(); result=observe_retirement(420,lambda rank,t:quiet(19 if rank else 0),lambda x:None,clock,clock.sleep)
        self.assertTrue(result['nativeProcessesAbsent']);self.assertFalse(result['journalsEmpty']);self.assertEqual(clock.now,0)
    def test_active_process_holds_full_window_without_fabricated_absence(self):
        clock=Clock(); result=observe_retirement(420,lambda rank,t:dict(quiet(),active=['owned-native']),lambda x:None,clock,clock.sleep)
        self.assertEqual(clock.now,420);self.assertTrue(result['ownershipWindowExpired']);self.assertFalse(result['nativeProcessesAbsent'])
    def test_lost_host_holds_full_window(self):
        clock=Clock()
        def unavailable(rank,timeout):
            if rank:raise OSError('host unreachable')
            return quiet()
        result=observe_retirement(3,unavailable,lambda x:None,clock,clock.sleep)
        self.assertEqual(clock.now,3);self.assertFalse(result['nativeProcessesAbsent']);self.assertFalse(result['journalsEmpty'])
        self.assertEqual(len(result['observationErrors']),3)
    def test_stale_success_cannot_survive_later_observation_failure(self):
        clock=Clock()
        def collect(rank,timeout):
            if clock.now:raise TimeoutError('observation ended')
            return dict(quiet(),active=['native'] if rank else [])
        result=observe_retirement(2,collect,lambda x:None,clock,clock.sleep)
        self.assertFalse(result['nativeProcessesAbsent']);self.assertFalse(result['journalsEmpty'])
    def test_operator_interrupt_is_retained_while_cleanup_continues(self):
        clock=Clock()
        def collect(rank,timeout):
            if clock.now==0:raise KeyboardInterrupt()
            return quiet()
        result=observe_retirement(5,collect,lambda x:None,clock,clock.sleep)
        self.assertEqual(clock.now,1);self.assertIn('KeyboardInterrupt',result['interrupted']);self.assertTrue(result['nativeProcessesAbsent'])
    def test_boolean_journal_is_refused(self):
        clock=Clock();result=observe_retirement(1,lambda rank,t:quiet(False),lambda x:None,clock,clock.sleep)
        self.assertFalse(result['journalsEmpty']);self.assertTrue(result['ownershipWindowExpired'])
    def test_per_call_timeout_never_exceeds_remaining_window(self):
        clock=Clock();timeouts=[]
        def collect(rank,timeout):
            timeouts.append(timeout);clock.now+=0.75;return dict(quiet(),active=['native'])
        result=observe_retirement(1,collect,lambda x:None,clock,clock.sleep)
        self.assertEqual(timeouts,[1,0.25]);self.assertTrue(result['ownershipWindowExpired'])

class ControllerChecks(unittest.TestCase):
    def run_child(self, code, timeout):
        receipt={}
        with tempfile.TemporaryDirectory() as directory:
            out=Path(directory)/'stdout';err=Path(directory)/'stderr'
            with out.open('wb') as stdout,err.open('wb') as stderr:
                try:invoke_controller([sys.executable,'-c',code],stdout,stderr,receipt,timeout)
                except subprocess.TimeoutExpired:receipt['timeoutRaised']=True
            return receipt,out.read_bytes(),err.read_bytes()
    def test_normal_real_child_reaped(self):
        receipt,out,err=self.run_child("print('complete')",2)
        self.assertEqual(receipt['exitCode'],0);self.assertTrue(receipt['reaped']);self.assertTrue(receipt['groupAbsent'])
        self.assertFalse(receipt['killedOwnedGroup']);self.assertEqual(out,b'complete\n');self.assertEqual(err,b'')
    def test_timeout_real_child_fenced_reaped_and_failed(self):
        receipt,out,err=self.run_child("import time;print('started',flush=True);time.sleep(30)",0.2)
        self.assertTrue(receipt['timeoutRaised']);self.assertLess(receipt['exitCode'],0);self.assertTrue(receipt['reaped'])
        self.assertTrue(receipt['killedOwnedGroup']);self.assertTrue(receipt['groupAbsent']);self.assertEqual(out,b'started\n')
    def test_real_failure_is_not_relabelled_success(self):
        receipt,out,err=self.run_child("import sys;print('failed',file=sys.stderr);sys.exit(7)",2)
        self.assertEqual(receipt['exitCode'],7);self.assertTrue(receipt['reaped']);self.assertEqual(err,b'failed\n')
    def test_wait_reaped_before_keyboard_interrupt_receives_no_destructive_signal(self):
        class ReapedOnInterrupt:
            pid = 424242
            returncode = None
            def wait(self, timeout):
                if self.returncode is not None:
                    raise AssertionError('Already reaped child must not be waited again')
                self.returncode = 0  # Mirrors Popen.wait's internal KeyboardInterrupt wait.
                raise KeyboardInterrupt('interrupted after internal reap')
            def poll(self): raise AssertionError('Must not poll before ownership decision')
            def kill(self): raise AssertionError('Must not signal an already-reaped child')
        child = ReapedOnInterrupt(); receipt = {}; signals = []
        def observed_group(pid, number):
            signals.append((pid, number))
            if number != 0: raise AssertionError('Destructive signal after reaping')
            raise ProcessLookupError()
        with patch('parent_cleanup.subprocess.Popen', return_value=child), patch('parent_cleanup.os.killpg', side_effect=observed_group):
            with self.assertRaisesRegex(KeyboardInterrupt, 'interrupted after internal reap'):
                invoke_controller(['fabricated-controller'], io.BytesIO(), io.BytesIO(), receipt)
        self.assertEqual(signals, [(child.pid, 0)])
        self.assertTrue(receipt['reapedBeforeExceptionCleanup']); self.assertTrue(receipt['reaped'])
        self.assertTrue(receipt['groupAbsent']); self.assertFalse(receipt['killedOwnedGroup'])
        self.assertEqual(receipt['exitCode'], 0); self.assertIn('KeyboardInterrupt', receipt['failure'])
    def test_parent_orders_postflight_before_alias_release(self):
        source=(Path(__file__).parent/'run_physical.py').read_text()
        self.assertLess(source.index('cleanup = observe_retirement'),source.index("lease.stdin.write(b'release\\n')"))
        self.assertIn("record.get('nativeProcessesAbsent') is True and record.get('journalsEmpty') is True",source)
        self.assertIn("record.get('localController', {}).get('reaped') is True",source)
        ast.parse(source,feature_version=(3,9))

if __name__=='__main__':unittest.main()
