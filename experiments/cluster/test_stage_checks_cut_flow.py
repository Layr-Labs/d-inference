"""Short-rank unequal geometry through fake cohort supervision and stream parsing."""
import copy
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from runtime.stage_checks import ranks
from runtime.stage_checks.common import canonical
from runtime.stage_checks.supervision import run
from stage_cut_test_support import EPOCH,context,reports
from test_stage_checks_supervision import Child,Clock


class CutFlowTests(unittest.TestCase):
    def setUp(self):
        for target in ('subprocess.Popen','subprocess.run','socket.socket'):
            guard=patch(target,side_effect=AssertionError('No actual process/socket calls'));guard.start();self.addCleanup(guard.stop)
        temporary=tempfile.TemporaryDirectory();self.addCleanup(temporary.cleanup);self.path=Path(temporary.name)
        self.clock=Clock();self.children=[];self.stops=0

    def execute(self,cut=12,stale=False,finish=.1):
        ctx=context(cut=cut);values=reports(context() if stale else ctx);cohort=[]
        for rank in (0,1):
            directory=self.path/str(rank);directory.mkdir();cohort.append(dict(rank=rank,local=str(directory)))
        def start(rank):
            index=rank['rank'];terminal=values[index]
            ready={key:terminal[key] for key in ('schemaVersion','rank','worldSize','epoch','transport','backend')}
            ready['kind']=ranks.READY
            Path(rank['local'],'stdout.jsonl').write_bytes(canonical(ready)+b'\n'+canonical(terminal)+b'\n')
            child=Child(index,self.clock,finish,0);self.children.append(child);return child
        def stop(_ranks,children):
            self.stops+=1
            for child in children:child.finish=self.clock();child.code=-15
        return run(cohort,EPOCH,ctx,ranks,1,start,stop,lambda:None,clock=self.clock,sleep=self.clock.sleep)

    def test_unequal_complete_pair_keeps_baseline_qualification_false(self):
        result,values=self.execute()
        self.assertTrue(result['passed']);self.assertTrue(result['supervisors_reaped']);self.assertEqual(self.stops,0)
        self.assertEqual([child.waits for child in self.children],[1,1])
        self.assertEqual(result['validation']['frames_per_rank'],6);self.assertFalse(result['validation']['baseline_compared'])
        self.assertEqual(values[1]['frames'][0]['capture']['sourceLayerStart'],12)

    def test_stale_half_output_fences_both_live_ranks(self):
        result,_=self.execute(stale=True,finish=5)
        self.assertFalse(result['passed']);self.assertEqual(self.stops,1)
        self.assertTrue(result['supervisors_reaped']);self.assertIn('Wrong global stage range',result['error'])

    def test_unequal_timeout_keeps_existing_cohort_cleanup(self):
        result,_=self.execute(finish=5)
        self.assertFalse(result['passed']);self.assertEqual(result['cancellation_reason'],'cohort_deadline')
        self.assertEqual(self.stops,1);self.assertTrue(result['supervisors_reaped'])


if __name__=='__main__':unittest.main()
