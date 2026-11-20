"""Injected-clock/process tests; never start a native worker or open a socket."""
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from stage_checks import p2p
from stage_checks.stream import Records
from stage_checks.supervision import run

EPOCH='a'*32


def rows(rank):
    ready=dict(kind=p2p.READY,schemaVersion=1,epoch=EPOCH,rank=rank,worldSize=2,
               transport='loopback-test',backend='ring')
    terminal=dict(ready,kind=p2p.TERMINAL,passed=True,correctnessOnly=True,
        throughputMeasurementValid=False,modelForwardCompared=False,physicalTransferQualified=False,
        fixtureFingerprint='b'*64,controlCases=[dict(control=i)for i in range(7)],
        cases=[dict(caseID=f'{dtype}-h{width}',complete=True,
            frames=[dict(payloadSHA256='c'*64,headerSHA256='d'*64,nativeBytesExact=True)for _ in range(6)])
            for dtype in('float32','float16','bfloat16')for width in(128,4096,8192)])
    return [ready,terminal]


class Clock:
    value=0
    def __call__(self):return self.value
    def sleep(self,delay):self.value+=delay


class Child:
    def __init__(self,rank,clock,finish,code):
        self.pid=7000+rank;self.clock=clock;self.finish=finish;self.code=code;self.waits=0
    def poll(self):return self.code if self.clock()>=self.finish else None
    def wait(self,timeout):
        assert self.poll()is not None
        self.waits+=1;return self.code


class SupervisionTests(unittest.TestCase):
    def setUp(self):
        for name in ('subprocess.Popen','subprocess.run','socket.socket'):
            guard=patch(name,side_effect=AssertionError('No native/process/socket calls'))
            guard.start();self.addCleanup(guard.stop)
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.ranks=[];self.children=[];self.stops=0;self.clock=Clock()
        for rank in (0,1):
            path=Path(self.temp.name)/str(rank);path.mkdir()
            self.ranks.append(dict(rank=rank,local=str(path)))
    def execute(self,finish=(.1,.1),codes=(0,0),mutate=None,start_failure=None,memory=None):
        def start(rank):
            i=rank['rank']
            if i==start_failure:raise RuntimeError('Injected second spawn failure')
            values=rows(i)
            if mutate:values=mutate(i,values)
            raw=values if isinstance(values,bytes) else b''.join(json.dumps(row).encode()+b'\n'for row in values)
            (Path(rank['local'])/'stdout.jsonl').write_bytes(raw)
            child=Child(i,self.clock,finish[i],codes[i]);self.children.append(child);return child
        def stop(_ranks,children):
            self.stops+=1
            for child in children:
                if child.poll()is None:child.finish=self.clock();child.code=-15
        return run(self.ranks,EPOCH,dict(mode='p2p'),p2p,1,start,stop,memory or (lambda:None),
                   clock=self.clock,sleep=self.clock.sleep)
    def assert_retired(self,result):
        self.assertFalse(result['passed']);self.assertEqual(self.stops,1)
        self.assertTrue(all(child.poll()is not None and child.waits==1 for child in self.children))
    def test_positive_pair_validates_and_reaps_without_cancel(self):
        result,reports=self.execute()
        self.assertTrue(result['passed']);self.assertTrue(result['supervisors_reaped'])
        self.assertEqual(result['validation']['residuals_per_rank'],54)
        self.assertEqual(len(reports),2);self.assertEqual(self.stops,0)
        self.assertTrue(all(child.waits==1 for child in self.children))
    def test_already_exited_workers_have_completed_stdout_drained(self):
        result,_=self.execute(finish=(0,0))
        self.assertTrue(result['passed']);self.assertEqual(self.stops,0)
    def test_peer_exit_fences_live_cohort(self):
        result,_=self.execute(finish=(.1,10),codes=(7,0))
        self.assert_retired(result);self.assertEqual(result['cancellation_reason'],'rank_failed')
        self.assertEqual(result['exit_codes'],[7,-15])
    def test_parent_deadline_fences_both(self):
        result,_=self.execute(finish=(10,10))
        self.assert_retired(result);self.assertEqual(result['cancellation_reason'],'cohort_deadline')
    def test_partial_eof_fences_peer(self):
        result,_=self.execute(finish=(0,10),mutate=lambda rank,values:values[:1] if rank==0 else values)
        self.assert_retired(result);self.assertIn('EOF without completed report',result['error'])
    def test_wrong_ready_epoch_fences_both(self):
        def change(rank,values):
            if rank==1:values[0]['epoch']='f'*32
            return values
        result,_=self.execute(finish=(10,10),mutate=change)
        self.assert_retired(result);self.assertIn('cohort identity',result['error'])
    def test_second_spawn_failure_reaps_first(self):
        result,_=self.execute(finish=(10,10),start_failure=1)
        self.assert_retired(result);self.assertFalse(result['supervisors_reaped'])
        self.assertEqual(len(self.children),1)
    def test_memory_failure_fences_both(self):
        def refused():raise ValueError('Reported swap increased')
        result,_=self.execute(finish=(10,10),memory=refused)
        self.assert_retired(result);self.assertIn('Reported swap increased',result['error'])
    def test_duplicate_terminal_and_wrong_namespace_fail(self):
        for mutation in (lambda rank,values:values+[values[1]],
                         lambda rank,values:[dict(values[0],kind='completed')]+values[1:]):
            with self.subTest(mutation=mutation):
                values=mutation(0,rows(0));path=Path(self.ranks[0]['local'])
                (path/'stdout.jsonl').write_text(''.join(json.dumps(row)+'\n'for row in values))
                with self.assertRaises(ValueError):Records(path,0,EPOCH,dict(mode='p2p'),p2p).poll(final=True)


if __name__=='__main__':unittest.main()
