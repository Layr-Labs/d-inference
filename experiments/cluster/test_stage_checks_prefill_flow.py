"""Fake whole-cohort fencing and pre-hash admission ordering for the new mode."""
from contextlib import redirect_stdout
import copy
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from runtime.stage_checks import cli,prefill
from runtime.stage_checks.common import canonical,digest
from runtime.stage_checks.supervision import run
from stage_prefill_test_support import EPOCH,context,rows
from test_stage_checks_supervision import Child,Clock


class PrefillFlowTests(unittest.TestCase):
    def setUp(self):
        for target in ('subprocess.Popen','subprocess.run','socket.socket'):
            guard=patch(target,side_effect=AssertionError('No process/socket calls'));guard.start();self.addCleanup(guard.stop)
        self.temporary=tempfile.TemporaryDirectory();self.addCleanup(self.temporary.cleanup)
        self.base=Path(self.temporary.name);self.clock=Clock();self.ctx=context();self.children=[];self.stops=0
        self.ranks=[]
        for rank in (0,1):
            path=self.base/str(rank);path.mkdir();self.ranks.append(dict(rank=rank,local=str(path)))

    def execute(self,mutate=None,finish=(.1,.1),codes=(0,0)):
        def start(rank):
            i=rank['rank'];values=rows(i,self.ctx)
            if mutate:values=mutate(i,values)
            (Path(rank['local'])/'stdout.jsonl').write_bytes(b''.join(canonical(v)+b'\n' for v in values))
            child=Child(i,self.clock,finish[i],codes[i]);self.children.append(child);return child
        def stop(_ranks,children):
            self.stops+=1
            for child in children:
                if child.poll()is None:child.finish=self.clock();child.code=-15
        return run(self.ranks,EPOCH,self.ctx,prefill,1,start,stop,lambda:None,clock=self.clock,sleep=self.clock.sleep)

    def test_valid_outer_pair_reaps_and_leaves_numeric_audit_false(self):
        result,_=self.execute();self.assertTrue(result['passed']);self.assertEqual(self.stops,0)
        self.assertFalse(result['validation']['numerical_audit_performed'])
        self.assertTrue(all(child.waits==1 for child in self.children))

    def test_ready_peer_mismatch_fences_before_terminal(self):
        def mutate(rank,values):
            if rank==1:
                value=copy.deepcopy(values[0]);value['agreement']['producerStageFingerprint']='0'*64
                value['agreementFingerprint']=digest(b'qwen-prefill-start-agreement-v1\n'+canonical(value['agreement']))
                return [value]
            return values[:1]
        result,_=self.execute(mutate=mutate,finish=(10,10))
        self.assertFalse(result['passed']);self.assertIn('Peer ready agreement',result['error']);self.assertEqual(self.stops,1)
        self.assertTrue(all(child.poll()is not None and child.waits==1 for child in self.children))

    def test_deadline_and_peer_exit_fence_both_owned_ranks(self):
        result,_=self.execute(finish=(10,10));self.assertEqual(result['cancellation_reason'],'cohort_deadline')
        self.assertEqual(self.stops,1);self.assertFalse(result['passed'])

    def cli_args(self,output):
        runtime=self.base/'repo/experiments/cluster/runtime';runtime.mkdir(parents=True,exist_ok=True)
        return ['prefill-ranks','--runtime',str(runtime),'--output',str(output),'--release','/unused-release',
            '--expected-binary-sha256','a'*64,'--model-dir','/model-not-opened','--artifact-aggregate-sha256','b'*64,
            '--tokens-file','/not-read','--stage-prefill-policy','serial_v1','--stage-logits-dtype','bfloat16',
            '--baseline-jsonl','/not-read','--baseline-sha256','c'*64,'--baseline-evidence-sha256','d'*64]

    def test_refused_initial_free_does_not_snapshot_hash_or_spawn(self):
        output=self.base/'refused'
        with patch.object(cli,'initial_free_screen',return_value={'passed':False}), \
             patch.object(cli.archive,'archive_launcher',side_effect=AssertionError('Must not snapshot')) as archive, \
             patch.object(cli,'MemoryGate',side_effect=AssertionError('Must not create later gate')),redirect_stdout(io.StringIO()):
            self.assertEqual(cli.main(self.cli_args(output)),1)
        archive.assert_not_called()
        from runtime.stage_checks.common import parse
        record=parse((output/'receipt.json').read_bytes())
        self.assertFalse(record['native_execution_attempted']);self.assertFalse(record['passed'])

    def test_initial_free_and_swap_reference_precede_any_snapshot(self):
        order=[]
        class Gate:
            samples=[]
            def __init__(self):order.append('swap-reference')
        def initial():order.append('actual-free');return {'passed':True}
        def archive(_):order.append('snapshot');raise ValueError('Stop fake before file/archive work')
        with patch.object(cli,'initial_free_screen',side_effect=initial),patch.object(cli,'MemoryGate',Gate), \
             patch.object(cli.archive,'archive_launcher',side_effect=archive),redirect_stdout(io.StringIO()):
            self.assertEqual(cli.main(self.cli_args(self.base/'ordered')),1)
        self.assertEqual(order,['actual-free','swap-reference','snapshot'])


if __name__=='__main__':unittest.main()
