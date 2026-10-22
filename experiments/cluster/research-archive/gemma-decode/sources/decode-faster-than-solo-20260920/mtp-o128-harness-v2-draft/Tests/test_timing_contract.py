"""Synthetic bounded timing-reader controls; no native facts are created."""
import copy,sys,unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
sys.path[:0]=[str(ROOT/'proposed'),str(ROOT.parent/'mtp-o128-harness-draft/proposed/numerical')]
from timing_contract import FLAGS,PHASES,TARGET,COUNTS,request_timing,validate_cohort_timing

def fixture(output=16):
    rows=[];widths=[];accepted=[]
    for i in range(output//2):
        row={k:0 for k in (*PHASES,*TARGET)}
        row.update(ordinal=i,kind='prime' if i==0 else 'verification',width=1 if i==0 else 2,accepted=0 if i==0 else 1,
            totalNanoseconds=10,targetNanoseconds=6,targetPrepareNanoseconds=1,targetAdmissionNanoseconds=2,targetExecutionNanoseconds=3,
            selectionNanoseconds=1,reconcileNanoseconds=1)
        rows.append(row);widths.append(row['width']);accepted.append(row['accepted'])
    delta=dict(sends=10,receives=10,completedOperations=20,entryResourceChecks=20,exitResourceChecks=20,innerLifetimeChecks=300)
    timing=dict(FLAGS,schema='gemma4_remote_mtp_target_window_timings_v1',maximumRecords=128,windows=rows,finalFinishNanoseconds=1,controlDelta=delta)
    return dict(phaseTiming=timing,verificationWidths=widths,acceptedPrefixes=accepted,decodeNanoseconds=len(rows)*10+2)

class Timing(unittest.TestCase):
    def reject(self,change):
        row=fixture();change(row)
        with self.assertRaises((ValueError,KeyError)):request_timing(row,16,1)
    def test_short_and_long_coverage(self):
        for output in (16,128):request_timing(fixture(output),output,1)
    def test_exact_fields_and_flags(self):
        self.reject(lambda r:r['phaseTiming'].__setitem__('guess',0))
        self.reject(lambda r:r['phaseTiming'].__setitem__('assistantGPUTimeMeasured',True))
        self.reject(lambda r:r['phaseTiming'].__setitem__('sameTargetProcessWallClock',1))
    def test_window_prefix_substitution(self):
        self.reject(lambda r:r['phaseTiming']['windows'][1].__setitem__('width',3))
        self.reject(lambda r:r['phaseTiming']['windows'][1].__setitem__('accepted',0))
        self.reject(lambda r:r['phaseTiming']['windows'][1].__setitem__('ordinal',0))
    def test_nested_target_total_cannot_exceed_parent(self):
        self.reject(lambda r:r['phaseTiming']['windows'][1].__setitem__('targetExecutionNanoseconds',7))
    def test_disjoint_phases_cannot_exceed_window(self):
        self.reject(lambda r:r['phaseTiming']['windows'][1].__setitem__('proposalDrainNanoseconds',3))
    def test_window_total_cannot_exceed_decode(self):
        self.reject(lambda r:r.__setitem__('decodeNanoseconds',1))
    def test_uint_and_kind_are_strict(self):
        for v in (True,-1,2**64,1.0):self.reject(lambda r,v=v:r['phaseTiming']['windows'][1].__setitem__('targetNanoseconds',v))
        self.reject(lambda r:r['phaseTiming']['windows'][1].__setitem__('kind','prime'))
    def test_request_control_chronology(self):
        self.reject(lambda r:r['phaseTiming']['controlDelta'].__setitem__('exitResourceChecks',19))
    def test_cohort_barriers_join_exactly(self):
        value=dict(samples=[fixture() for _ in range(4)],controlResourceMetrics=dict(sends=46,receives=46,
            completedOperations=92,entryResourceChecks=92,exitResourceChecks=92,innerLifetimeChecks=1300))
        validate_cohort_timing(value,dict(outputCount=16),dict(maximumDraftTokens=1))
        value['controlResourceMetrics']['sends']+=1
        with self.assertRaises(ValueError):validate_cohort_timing(value,dict(outputCount=16),dict(maximumDraftTokens=1))

if __name__=='__main__':unittest.main()
