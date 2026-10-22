"""Pure reader controls only; fabricated counters establish no native completion."""
import copy,sys,unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parent.parent
BASE=Path('/Users/developer/DarkbloomDev/cluster-research/gemma4-mtp-remote-packed-head-physical-20260920')
sys.path[:0]=[str(ROOT/'proposed/package'),str(BASE/'package')]
from control_contract import POLICY,validate_control_metrics
def fixture():
    return dict(guardObservationPolicy=POLICY,controlResourceObservationPolicy=POLICY,
        guardMetrics=dict(records=[dict(category='wireSendCompleted',count=10),dict(category='wireReceiveCompleted',count=10)]),
        controlResourceMetrics=dict(schema='gemma4_remote_control_resource_counters_v1',policy=POLICY,frameBytes=16384,
            sends=10,receives=10,completedOperations=20,entryResourceChecks=20,exitResourceChecks=20,innerLifetimeChecks=300,
            resourceValuesCachedAcrossOperations=False,snapshotResourceCadenceChanged=False,nativeCompletionFencesChanged=False,failed=False))
class Control(unittest.TestCase):
    def test_completed_scalar_chronology_accepts(self):validate_control_metrics(fixture())
    def test_wall_counter_join_refuses_substitution(self):
        for rows in [[],[dict(category='wireSendCompleted',count=10)],
            [dict(category='wireSendCompleted',count=9),dict(category='wireReceiveCompleted',count=10)],
            [dict(category='wireSendCompleted',count=10.0),dict(category='wireReceiveCompleted',count=10)],
            [dict(category='wireSendCompleted',count=10)]*2+[dict(category='wireReceiveCompleted',count=10)]]:
            row=fixture();row['guardMetrics']['records']=rows
            with self.assertRaises(ValueError):validate_control_metrics(row)
    def test_old_or_mixed_policy_refuses(self):
        for name in ['guardObservationPolicy','controlResourceObservationPolicy']:
            row=fixture();row[name]='gemma4_invocation_fresh_observation_v1'
            with self.assertRaises(ValueError):validate_control_metrics(row)
    def test_missing_or_extra_counter_fields_refuse(self):
        for name in list(fixture()['controlResourceMetrics']):
            row=fixture();del row['controlResourceMetrics'][name]
            with self.assertRaises(ValueError):validate_control_metrics(row)
        row=fixture();row['controlResourceMetrics']['guessed']=0
        with self.assertRaises(ValueError):validate_control_metrics(row)
    def test_counter_identity_refuses(self):
        for name,new in [('schema','other'),('policy','other'),('frameBytes',256),('frameBytes',16384.0)]:
            row=fixture();row['controlResourceMetrics'][name]=new
            with self.assertRaises(ValueError):validate_control_metrics(row)
    def test_counts_are_exact_uint64(self):
        for name in ['sends','receives','completedOperations','entryResourceChecks','exitResourceChecks','innerLifetimeChecks']:
            for new in [True,False,-1,0,2**64,20.0]:
                row=fixture();row['controlResourceMetrics'][name]=new
                with self.assertRaises(ValueError):validate_control_metrics(row)
    def test_missing_entry_exit_or_matching_reply_refuses(self):
        for name,new in [('sends',11),('receives',9),('completedOperations',19),('entryResourceChecks',19),('exitResourceChecks',19),('innerLifetimeChecks',19)]:
            row=fixture();row['controlResourceMetrics'][name]=new
            with self.assertRaises(ValueError):validate_control_metrics(row)
    def test_partial_cohort_refuses(self):
        row=fixture();row['controlResourceMetrics'].update(sends=5,receives=5,completedOperations=10,entryResourceChecks=10,exitResourceChecks=10)
        with self.assertRaises(ValueError):validate_control_metrics(row)
    def test_failure_or_changed_fence_or_cached_observation_refuses(self):
        for name in ['resourceValuesCachedAcrossOperations','snapshotResourceCadenceChanged','nativeCompletionFencesChanged','failed']:
            for new in [True,0]:
                row=fixture();row['controlResourceMetrics'][name]=new
                with self.assertRaises(ValueError):validate_control_metrics(row)
if __name__=='__main__':unittest.main()
