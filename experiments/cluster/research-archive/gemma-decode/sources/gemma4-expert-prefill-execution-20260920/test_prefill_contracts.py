"""Fabricated parser/binding controls, staged only; no children, model or native IO."""
import copy
import unittest
from test_contracts import fixture, policy, difference, H
from expert_results import digest, scope, validate_result, validate_pair
from gemma_inputs import validate_job
from build_binding import ROOT, compose


def expanded(rank, rows):
    job,value=fixture(rank);native=job['nativeJob'];native['tokenCounts']=[rows]
    value['job']=native;value['scopeSHA256']=scope(native)
    comparison=fixture(0)[1]['cases'][0]['comparison']
    comparison.update(tokenCount=rows,selectedGlobalIDs=comparison['selectedGlobalIDs']*rows,
        assignmentCounts=[rows*4,rows*4],expertOutputs=difference(rows*8*2816),
        weighted=difference(rows*2816),postNorm=difference(rows*2816),
        projectionPolicies=[policy(rows*8,128,48,rows*4,True,True,rows*4),
                            policy(rows*8,128,80,rows*4,True,True,320 if rows==64 else 512)])
    case=value['cases'][0]
    case.update(tokenCount=rows,localAssignmentCount=rows*4,routeSHA256=digest(comparison['selectedGlobalIDs']),
                referenceResultSHA256=digest(comparison))
    if rank==0:case['comparison']=comparison
    value['sentTensorBytes']=(rows if rank==0 else rows*4)*2816*2
    value['receivedTensorBytes']=(rows*4 if rank==0 else rows)*2816*2
    return job,value


class PrefillContracts(unittest.TestCase):
    def test_seven_case_job_and_exact_closed_refusals(self):
        job,_=fixture(0);job['nativeJob']['tokenCounts']=[1,7,8,9,33,64,128];validate_job(job)
        for counts in ([34],[129],[64,64],[128,64],[True],list(range(1,9))):
            bad=copy.deepcopy(job);bad['nativeJob']['tokenCounts']=counts
            with self.assertRaises(ValueError):validate_job(bad)

    def test_c64_sorted_projection_keeps_original_wire_rows(self):
        a,left=expanded(0,64);b,right=expanded(1,64)
        validate_result(left,a);validate_result(right,b);validate_pair(left,right)
        self.assertEqual(left['cases'][0]['comparison']['projectionPolicies'][1]['executedAssignments'],320)
        self.assertEqual(right['cases'][0]['localAssignmentCount'],256)

    def test_c128_exact_values_and_bilateral_accounting(self):
        a,left=expanded(0,128);b,right=expanded(1,128)
        validate_result(left,a);validate_result(right,b);validate_pair(left,right)
        for change in ('raw','weighted','postnorm','traffic'):
            bad=copy.deepcopy(left);case=bad['cases'][0]['comparison']
            if change=='traffic':bad['receivedTensorBytes']+=2
            else:case[{'raw':'expertOutputs','weighted':'weighted','postnorm':'postNorm'}[change]]['candidateSHA256']='f'*64
            with self.assertRaises(ValueError):validate_result(bad,a)

    def test_old_bound_or_padded_rows_cannot_qualify(self):
        for change in ('old-bound','weighted-rank-sum','padded-wire'):
            job,value=expanded(0,64);case=value['cases'][0]['comparison']
            if change=='old-bound':case['projectionPolicies'][0]['globalAssignments']=264
            elif change=='weighted-rank-sum':case['weighted']['exactBytes']=False
            else:value['receivedTensorBytes']=(320*2816*2)
            with self.assertRaises(ValueError):validate_result(value,job)

    def test_binding_refuses_absent_actual_build_receipts(self):
        missing=dict(path=str(ROOT/'absent-native-build-receipt.json'),sha256=H)
        with self.assertRaises(ValueError):compose(missing,missing,missing)

    def test_new_native_description_refuses_old_assignment_and_staging_bounds(self):
        from validate_description import validate
        job,_=fixture(0);native=job['nativeJob'];native['tokenCounts']=[1,7,8,9,33,64,128]
        # Read the source-bound expected DTO by spelling out the actual contract.
        value=dict(schema='gemma4_expert_rdma_capability_v1',scopeSHA256=scope(native),rank=0,
            globalLayerIndex=0,globalExpertIDsByRank=[list(range(48)),list(range(48,128))],
            tokenCounts=native['tokenCounts'],topK=8,hiddenSize=2816,intermediateSize=704,dtype='bfloat16',
            maximumAssignments=1024,maximumControlBytes=32768,maximumTensorBytes=8388608,
            maximumRecordsPerDirection=128,extraNativeStagingBytes=33554432,extraHostStagingBytes=33554432,
            minimumActualFreeBytes=6*1024**3,requiresAC=True,requiredPressureLevel=1,maximumSwapBytes=0,
            metadataOnly=True,nativeExecuted=False,sourcePayloadVerified=False,
            deviceOnlyDynamicRoutingQualified=False,encryptedRDMA=False,runtimeServingEnabled=False,
            buildIdentityRequiresParentVerification=True)
        binding={'products':[{'product':'GemmaExpertRDMACheck','sha256':H}]}
        validate(native,value,binding)
        for field,old in [('maximumAssignments',264),('maximumTensorBytes',2097152),
                          ('extraNativeStagingBytes',16777216),('extraHostStagingBytes',16777216),
                          ('maximumAssignments',1024.0),('runtimeServingEnabled',True)]:
            bad=copy.deepcopy(value);bad[field]=old
            with self.assertRaises(ValueError):validate(native,bad,binding)


if __name__=='__main__':unittest.main()
