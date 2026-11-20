"""Fabricated parser controls only; never an actual GPU qualification."""
import copy
from pathlib import Path
import sys
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'package'))
from qmv_contract import expected,mode_for_run,validate_result,RESERVE

def fixture(mode):
    rows=[]
    for name,base in expected(mode).items():
        row=dict(base,name=name,passed=True,exactOutputBytes=True,finite=True,maximumDifferentBytes=0,
            referenceSHA256='a'*64,candidateSHA256='a'*64,referenceNanoseconds=[1,2,3],candidateNanoseconds=[1,2,3])
        if mode=='dense':row.update(currentBatchExactToM1=False,currentBatchSHA256='b'*64,
            currentBatchNanoseconds=[1,2,3],currentBatchMaximumAbsoluteError=1,currentBatchMaximumRelativeRMSError=0.1)
        elif name.startswith('gather/down/'):row.update(weightedOriginalSlotsExact=True,
            weightedReferenceSHA256='c'*64,weightedCandidateSHA256='c'*64)
        rows.append(row)
    return dict(schema='gemma_small_qmv_result_v1',mode='--'+mode,passed=True,caseCount=len(rows),cases=rows,
        warmupCount=1,measurementCount=3,gatheredDeviceRefusalControls=12 if mode=='gathered' else 0,
        nativeExtraReserveBytes=RESERVE,hostReserveBytes=RESERVE,cacheBytesAfterRelease=0,
        runtimeServingEnabled=False,modelExecuted=False,defaultDispatchChanged=False,
        physicalProcessOrLeaseRetirementEstablished=False,resourceObservations=1,
        minimumActualFreeBytes=10*1024**3+2*RESERVE,peakExtraActiveBytes=1)

class Contract(unittest.TestCase):
    def test_exact_named_membership(self):
        for mode in ['dense','gathered']:validate_result(fixture(mode),mode)
        bad=fixture('dense');bad['cases'][1]=copy.deepcopy(bad['cases'][0])
        with self.assertRaises(Exception):validate_result(bad,'dense')
    def test_exact_bytes_and_original_slots(self):
        bad=fixture('dense');bad['cases'][0]['candidateSHA256']='b'*64
        with self.assertRaises(Exception):validate_result(bad,'dense')
        bad=fixture('gathered');next(x for x in bad['cases'] if x['name'].startswith('gather/down/'))['weightedOriginalSlotsExact']=False
        with self.assertRaises(Exception):validate_result(bad,'gathered')
    def test_no_budget_or_model_claim_relaxation(self):
        for key,value in [('modelExecuted',True),('peakExtraActiveBytes',RESERVE+1),('minimumActualFreeBytes',10*1024**3)]:
            bad=fixture('dense');bad[key]=value
            with self.assertRaises(Exception):validate_result(bad,'dense')
    def test_mode_is_closed_by_bound_run_path(self):
        self.assertEqual(mode_for_run(Path('/runs/small-qmv-dense-1-full')),'dense')
        for name in ['small-qmv-dense-2-full','small-qmv-dense-1-full-x','small-qmv-remote-1-full']:
            with self.assertRaises(Exception):mode_for_run(Path('/runs')/name)

if __name__=='__main__':unittest.main()
