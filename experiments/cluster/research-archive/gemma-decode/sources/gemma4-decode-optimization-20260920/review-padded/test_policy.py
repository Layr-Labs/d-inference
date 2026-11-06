"""CPU contract controls; reads only the three small accepted timestamp reports."""
import copy
import unittest
import policy
import decode_summary

c=policy.base

# Explicit source-derived counts, independently written rather than generated
# with the function being tested. Categories retain c.GUARD_CATEGORIES order.
EXPECTED={
    0:{'global':[23391,46788,24040,70829,24047,24040,187146,713,713],
       'prefill':[3089,6178,3089,9267,3089,3089,24712,129,129],
       'decode':[975,1950,975,2925,975,975,7800,45,45]},
    1:{'global':[38265,76536,40338,116875,40345,40338,306138,713,713],
       'prefill':[2834,5668,2834,8502,2834,2834,22672,129,129],
       'decode':[945,1890,945,2835,945,945,7560,45,45]}}


def replace_counts(metrics,counts):
    for row,count in zip(metrics['records'],counts):row['count']=count


class PolicyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        h=c.HARNESS/'cases'
        cls.solo=c.joined.read(h/'p4096-cut7-c64-serial-v1/solo/full/native/worker-0.stdout')
        cls.old=[c.joined.read(h/f'p4096-cut7-c64-overlap-v1/pair/stage{rank}/native/worker-0.stdout') for rank in (0,1)]

    def candidate(self,rank):
        value=copy.deepcopy(self.old[rank]);replace_counts(value['guardMetrics'],EXPECTED[rank]['global'])
        for sample in value['samples']:
            for phase in ('prefill','decode'):replace_counts(sample['guardMetrics'][phase],EXPECTED[rank][phase])
        r=value['resources'];i=len(r['namedArrays'])-(1 if rank==0 else 0)
        r['namedArrays'].insert(i,dict(name='paddedControlFrame',bytes=16384))
        # Exercise actual-rounding semantics instead of assuming logical bytes.
        r['namedAllocationBounds'].insert(i,32768);r['namedNativeReserveBytes']+=32768
        r['hostEvidenceReserveBytes']+=32768;r['observationCount']-=8864
        return value

    def test_explicit_all_scope_counts(self):
        for rank in (0,1):
            for scope in ('global','prefill','decode'):
                metric=self.old[rank]['guardMetrics'] if scope=='global' else self.old[rank]['samples'][0]['guardMetrics'][scope]
                expected=dict(zip(c.GUARD_CATEGORIES,EXPECTED[rank][scope]))
                self.assertEqual(policy.expected_counts(c.guard_counts(metric),rank,scope),expected)

    def test_both_rank_deltas_and_unchanged_solo_accept(self):
        for rank in (0,1):
            candidate=self.candidate(rank)
            policy.cadence(candidate,self.old[rank],rank);receipt=policy.budget(candidate,self.old[rank],rank)
            self.assertEqual(receipt['actualExtraNativeBound'],32768)
        policy.cadence(self.solo,self.solo,None);policy.budget(self.solo,self.solo,None)

    def test_omitted_probe_and_release_counts_refuse(self):
        value=self.candidate(0)
        # Eight non-request controls: six probe controls, two final checkpoint controls.
        value['guardMetrics']['records'][0]['count']+=64
        with self.assertRaises(ValueError):policy.cadence(value,self.old[0],0)

    def test_wrong_wire_direction_refuses(self):
        old=c.guard_counts(self.old[0]['guardMetrics'])
        old['wireSendCompleted'],old['wireReceiveCompleted']=old['wireReceiveCompleted'],old['wireSendCompleted']
        with self.assertRaises(ValueError):policy.expected_counts(old,0,'global')

    def test_decode_guard_off_by_one_refuses(self):
        value=self.candidate(1);value['samples'][2]['guardMetrics']['decode']['records'][0]['count']-=1
        with self.assertRaises(ValueError):policy.cadence(value,self.old[1],1)

    def test_missing_receive_postprefix_reduction_refuses(self):
        value=self.candidate(0);value['samples'][1]['guardMetrics']['prefill']['records'][0]['count']+=129
        with self.assertRaises(ValueError):policy.cadence(value,self.old[0],0)

    def test_owner_commit_frontier_change_refuses(self):
        value=self.candidate(0);value['samples'][3]['frames'][-1]['ownerPhases'][-1]['committedTokens']-=1
        with self.assertRaises(ValueError):policy.cadence(value,self.old[0],0)

    def test_one_extra_global_os_read_refuses(self):
        value=self.candidate(1);value['guardMetrics']['records'][4]['count']+=1
        with self.assertRaises(ValueError):policy.cadence(value,self.old[1],1)

    def test_missing_host_charge_refuses(self):
        value=self.candidate(0);value['resources']['hostEvidenceReserveBytes']-=32768
        with self.assertRaises(ValueError):policy.budget(value,self.old[0],0)

    def test_undersized_native_bound_refuses(self):
        value=self.candidate(1);r=value['resources'];r['namedAllocationBounds'][-1]=16383
        r['namedNativeReserveBytes']-=32768-16383
        with self.assertRaises(ValueError):policy.budget(value,self.old[1],1)

    def test_original_bound_reduction_with_consistent_sum_refuses(self):
        value=self.candidate(0);r=value['resources'];r['namedAllocationBounds'][0]-=1;r['namedNativeReserveBytes']-=1
        with self.assertRaises(ValueError):policy.budget(value,self.old[0],0)

    def test_solo_budget_change_refuses(self):
        value=copy.deepcopy(self.solo);value['resources']['hostEvidenceReserveBytes']+=32768
        with self.assertRaises(ValueError):policy.budget(value,self.solo,None)

    def test_frame_or_cohort_truncation_refuses(self):
        value=self.candidate(1);value['samples'][1]['frames'].pop()
        with self.assertRaises(ValueError):policy.cadence(value,self.old[1],1)
        value=self.candidate(1);value['samples'].pop()
        with self.assertRaises(ValueError):policy.cadence(value,self.old[1],1)

    def test_boolean_rank_refuses(self):
        with self.assertRaises(ValueError):policy.expected_counts(c.guard_counts(self.old[0]['guardMetrics']),False,'global')

    def test_profile_is_local_and_has_45_tokens(self):
        for value in [self.solo]+self.old:
            result=decode_summary.summarize(value)
            self.assertEqual(result['decodeTokens'],45)
            self.assertFalse(result['pureNetworkOrGPUTimeMeasured'])
        value=copy.deepcopy(self.solo);value['samples'][2]['clockAcrossHostsCompared']=True
        with self.assertRaises(ValueError):decode_summary.summarize(value)

    def test_profile_bad_phase_chronology_refuses(self):
        value=copy.deepcopy(self.old[0]);f=value['samples'][1]['frames'][64]
        f['ownerPhases'][0]['timestampNanoseconds']=f['startedNanoseconds']-1
        with self.assertRaises(ValueError):decode_summary.summarize(value)


if __name__=='__main__':unittest.main()
