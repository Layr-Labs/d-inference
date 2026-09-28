"""Bounded CPU children only. Run after the root grants a quiet CPU slot."""
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from test_contracts import fixture

ROOT=Path(__file__).resolve().parent
sys.path.insert(0,str(ROOT/'package'))
from binding_common import parse, require
from expert_results import validate_result
from expert_retirement import collect_retired_result
from worker_contract import WorkerSpec
from worker_processes import PipeWorkers

class Retirement(unittest.TestCase):
    def opened(self,code,timeout=4):
        temporary=tempfile.TemporaryDirectory(prefix='expert-retirement-')
        self.addCleanup(temporary.cleanup)
        directory=Path(temporary.name).resolve()/'child'
        spec=WorkerSpec((sys.executable,'-B','-c',code),dict(os.environ),'solo',None)
        pipes=PipeWorkers((spec,),directory,timeout,lambda phase:None)
        self.addCleanup(lambda:pipes.close(kill=True))
        pipes.start()
        return pipes
    def assert_retired(self,pipes,codes):
        self.assertEqual([child.returncode for child in pipes.children],codes)
        self.assertTrue(pipes.closed)
        for child in pipes.children:
            with self.assertRaises(ProcessLookupError):os.killpg(child.pid,0)
    def record(self,passed=True):
        job,value=fixture(0)
        value['passed']=passed
        return job,value,json.dumps(value,separators=(',',':')).encode()+b'\n'
    def test_fragmented_numeric_failure_drains_and_reaps_natural_two(self):
        job,expected,raw=self.record(False)
        code='import os,time\nb='+repr(raw)+'\nfor i in range(0,len(b),113):\n os.write(1,b[i:i+113]);time.sleep(.001)\ntime.sleep(.03)\nraise SystemExit(2)'
        pipes=self.opened(code)
        actual,codes=collect_retired_result(pipes,lambda _,line:parse(line))
        self.assertEqual(actual,expected);self.assertEqual(codes,[2])
        self.assertTrue(pipes.complete_output);self.assertFalse(pipes.cleanup_errors)
        self.assertEqual((pipes.directory/'worker-0.stdout').read_bytes(),raw)
        self.assert_retired(pipes,[2])
        with self.assertRaises(ValueError):validate_result(actual,job)
        pipes.close(kill=True) # The production finally is harmless after actual retirement.
        self.assertFalse(pipes.cleanup_errors)
    def test_exact_success_and_natural_zero(self):
        job,expected,raw=self.record()
        pipes=self.opened('import os\nos.write(1,'+repr(raw)+')')
        actual,codes=collect_retired_result(pipes,lambda _,line:parse(line))
        validate_result(actual,job);require(codes==[0],'Worker exit was nonzero')
        self.assertTrue(pipes.complete_output);self.assert_retired(pipes,[0])
    def test_success_claim_with_exit_two_remains_failure(self):
        job,_,raw=self.record()
        pipes=self.opened('import os\nos.write(1,'+repr(raw)+')\nraise SystemExit(2)')
        actual,codes=collect_retired_result(pipes,lambda _,line:parse(line))
        validate_result(actual,job)
        with self.assertRaises(ValueError):require(codes==[0],'Worker exit was nonzero')
        self.assert_retired(pipes,[2]);self.assertTrue(pipes.complete_output)
    def test_trailing_event_is_not_a_complete_report(self):
        _,_,raw=self.record()
        pipes=self.opened('import os\nos.write(1,'+repr(raw+b'{}\n')+')')
        with self.assertRaises(ValueError):collect_retired_result(pipes,lambda _,line:parse(line))
        self.assertFalse(pipes.complete_output)
        pipes.close(kill=True);self.assert_retired(pipes,[pipes.children[0].returncode])
    def test_partial_eof_remains_failure(self):
        _,_,raw=self.record()
        pipes=self.opened('import os\nos.write(1,'+repr(raw[:-1])+')')
        with self.assertRaises(ValueError):collect_retired_result(pipes,lambda _,line:parse(line))
        self.assertFalse(pipes.complete_output)
        pipes.close(kill=True);self.assert_retired(pipes,[pipes.children[0].returncode])
    def test_unexpected_stderr_remains_failure(self):
        _,_,raw=self.record()
        pipes=self.opened('import os\nos.write(1,'+repr(raw)+')\nos.write(2,b"unexpected\\n")')
        with self.assertRaises(ValueError):collect_retired_result(pipes,lambda _,line:parse(line))
        self.assertFalse(pipes.complete_output)
        pipes.close(kill=True);self.assert_retired(pipes,[pipes.children[0].returncode])
    def test_hanging_after_report_keeps_original_absolute_expiry(self):
        _,_,raw=self.record()
        pipes=self.opened('import os,time\nos.write(1,'+repr(raw)+')\ntime.sleep(20)',timeout=1)
        with self.assertRaises(TimeoutError):collect_retired_result(pipes,lambda _,line:parse(line))
        pipes.close(kill=True)
        self.assertTrue(pipes.expired.is_set());self.assertFalse(pipes.complete_output)
        self.assert_retired(pipes,[-9])

if __name__=='__main__':unittest.main()
