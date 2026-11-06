"""Real state machine, fake child handles/clock/remote memory; never spawns."""
from pathlib import Path
import socket
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from long_rank_supervision import supervise
from long_rank_test_support import Child, INPUTS, EPOCH, fixtures, write_records
from long_rank_warning import WARNING


class Tests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='long-cohort-cpu-');self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)
        for obj,name in [(subprocess,'Popen'),(subprocess,'run'),(socket,'socket')]:
            p=patch.object(obj,name,side_effect=AssertionError('Real process/socket forbidden'));p.start();self.addCleanup(p.stop)

    def fake(self,codes,rows=None,memory=lambda seconds:None,second_start_failure=False,cleanup_failure=False,stderr=WARNING,memory_elapsed=0):
        ranks=[dict(rank=i,local=str(self.root/('rank-'+str(i))),directory='/owned/rank-'+str(i)) for i in range(2)]
        children=[Child(7101+i,code) for i,code in enumerate(codes)];stops=[];clock=[0.0]
        rows=[fixtures(0),fixtures(1)] if rows is None else rows
        for rank in ranks:Path(rank['local']).mkdir()
        def start(rank):
            i=rank['rank']
            if i==1 and second_start_failure:raise OSError('second SSH start failed')
            write_records(Path(rank['local']),rows[i],stderr);return children[i]
        def stop(values,started):
            stops.append((values,started))
            if cleanup_failure:raise OSError('remote cancellation failed')
            for child in started:
                if child.code is None:child.code=-15
        def sleep(seconds):clock[0]+=seconds
        def observe(seconds):
            memory(seconds);clock[0]+=memory_elapsed
        result=supervise(ranks,INPUTS,EPOCH,None,1,start,stop,observe,lambda:clock[0],sleep)
        return result,children,stops

    def test_fast_success_drains_both_and_reaps_local_handles(self):
        result,children,stops=self.fake([0,0])
        self.assertTrue(result['passed']);self.assertFalse(stops)
        self.assertEqual([p.waits for p in children],[1,1]);self.assertEqual(result['validation']['records_per_rank'],[2,2])
        self.assertFalse(result['remote_process_reaping_independently_verified'])

    def test_valid_different_peer_agreements_cancel_whole_cohort(self):
        result,_,stops=self.fake([None,None],[fixtures(0),fixtures(1,storage='f'*64)])
        self.assertFalse(result['passed']);self.assertIn('Peers disagree',result['error'])
        self.assertEqual(len(stops[0][0]),2)

    def test_peer_loss_keeps_exit_code_and_cancels_survivor(self):
        result,_,stops=self.fake([255,None],[[],[]])
        self.assertEqual(result['exit_codes'][0],255);self.assertTrue(stops);self.assertFalse(result['passed'])

    def test_parent_deadline_bounds_observation_and_cancels_both(self):
        calls=[];result,_,stops=self.fake([None,None],[[],[]],lambda seconds:calls.append(seconds))
        self.assertEqual(result['cancellation_reason'],'local_parent_deadline');self.assertTrue(stops)
        self.assertTrue(calls and all(0<x<=1 for x in calls))

    def test_primary_failure_survives_cancel_failure(self):
        def memory(seconds):raise ValueError('pressure failure')
        result,_,_=self.fake([None,None],[[],[]],memory,cleanup_failure=True)
        self.assertIn('pressure failure',result['error']);self.assertIn('remote cancellation failed',result['cleanup_errors'][0]['error'])
        self.assertFalse(result['passed'])

    def test_second_start_failure_cancels_both_owned_paths(self):
        result,_,stops=self.fake([None,None],[[],[]],second_start_failure=True)
        self.assertIn('second SSH start failed',result['error']);self.assertEqual(len(stops[0][0]),2)
        self.assertEqual(len(stops[0][1]),1)

    def test_missing_final_and_unexpected_stderr_fail_closed(self):
        result,_,stops=self.fake([0,0],[fixtures(0),fixtures(1)[:1]])
        self.assertIn('EOF without both',result['error']);self.assertTrue(stops)

    def test_extra_warning_bytes_fail_before_success(self):
        result,_,stops=self.fake([0,0],stderr=WARNING+b'extra\n')
        self.assertIn('stderr',result['error']);self.assertTrue(stops);self.assertFalse(result['passed'])

    def test_completed_clients_cannot_pass_after_observation_crosses_deadline(self):
        result,children,stops=self.fake([0,0],memory_elapsed=2)
        self.assertFalse(result['passed']);self.assertEqual(result['cancellation_reason'],'local_parent_deadline')
        self.assertTrue(stops);self.assertEqual([p.waits for p in children],[1,1])


if __name__=='__main__':unittest.main()
