"""Fabricated parser controls only: no MLX, children, sockets, or model reads."""
import copy
import hashlib
from pathlib import Path
import sys
import unittest
ROOT=Path(__file__).resolve().parent
sys.path.insert(0,str(ROOT/'package'))
from gemma_inputs import MODEL, validate_job
from expert_results import ARTIFACT, comparison, digest, scope, validate_result, validate_pair

H='1'*64

def difference(count):return dict(exactBytes=True,values=count,maximumAbsoluteError=0,relativeRMSError=0,referenceSHA256=H,candidateSHA256=H)
def fixture(rank):
    n=dict(schema='gemma4_expert_rdma_check_v1',modelDirectory=MODEL,membershipEpoch='11111111-1111-4111-8111-111111111111',
        requestID='22222222-2222-4222-8222-222222222222',buildIdentitySHA256=H,ownership='contiguous48_80',rank=rank,layer=0,tokenCounts=[1],timeoutSeconds=300)
    job=dict(schema='gemma4_expert_physical_job_v1',kind='rdma',mode='stage'+str(rank),layer=0,modelDirectory=MODEL,nativeSHA256=H,timeoutSeconds=300,nativeJob=n)
    c=dict(label='checkpoint-layer-0/two-rank/contiguous48_80',inputDType='bfloat16',tokenCount=1,topK=8,assignmentCounts=[4,4],
        selectedGlobalIDs=[[0,48,1,49,2,50,3,51]],routingWeightsSHA256=H,expertOutputs=difference(8*2816),weighted=difference(2816),postNorm=difference(2816))
    case=dict(ordinal=0,tokenCount=1,localAssignmentCount=4,routeSHA256=digest(c['selectedGlobalIDs']),inputSHA256=H,weightsSHA256=H,
        transferredOutputSHA256=H,referenceResultSHA256=digest(c),acceptedByReferenceRank=True)
    if rank==0:case['comparison']=c
    value=dict(schema='gemma4_expert_rdma_result_v1',job=n,scopeSHA256=scope(n),artifactAggregateSHA256=ARTIFACT,
        globalExpertIDsByRank=[list(range(48)),list(range(48,128))],loadedLocalExpertBytes=(48 if rank==0 else 80)*3345408,
        loadedReferenceExpertBytes=428212224 if rank==0 else 0,cases=[case],sentControlBytes=1000,receivedControlBytes=1000,
        sentTensorBytes=(1 if rank==0 else 4)*2816*2,receivedTensorBytes=(4 if rank==0 else 1)*2816*2,
        minimumActualFreeBytes=6*1024**3,maximumObservedActiveBytes=1,resourceObservations=3,reservedNativeBytes=1,hostReserveBytes=1,
        passed=True,expertBanksReleased=True,checkpointUnchanged=True,actualQuantizedTensorsExecuted=True,distributedExecution=True,
        authoritativeCPUFixtureRouteReadback=True,fullDecoderExecuted=False,deviceOnlyDynamicRoutingQualified=False,encryptedRDMA=False,
        runtimeServingEnabled=False,throughputMeasurementValid=False,wholeProcessMemoryBoundEstablished=False,
        physicalProcessOrLeaseRetirementEstablished=False,collectiveReleased=True,nativeCacheBytesAfterRelease=0,nativeExecuted=True)
    return job,value
class Contracts(unittest.TestCase):
    def test_both_exact_rank_reports_join(self):
        a,x=fixture(0);b,y=fixture(1);validate_result(x,a);validate_result(y,b);validate_pair(x,y)
    def test_changed_epoch_or_build_is_refused(self):
        for field in ('membershipEpoch','buildIdentitySHA256'):
            j,v=fixture(0);v=copy.deepcopy(v);v['job'][field]='3'*64
            with self.assertRaises(ValueError):validate_result(v,j)
    def test_inexact_values_or_missing_case_refused(self):
        for change in ('value','case'):
            j,v=fixture(0)
            if change=='value':v['cases'][0]['comparison']['weighted']['maximumAbsoluteError']=0.001
            else:v['cases']=[]
            with self.assertRaises(ValueError):validate_result(v,j)
    def test_substituted_slots_and_assignment_counts_refused(self):
        for change in ('slots','counts'):
            j,v=fixture(0);c=v['cases'][0]['comparison']
            if change=='slots':c['selectedGlobalIDs'][0][0]=48
            else:c['assignmentCounts']=[3,5]
            with self.assertRaises(ValueError):validate_result(v,j)
    def test_pair_result_or_traffic_mismatch_refused(self):
        for field in ('referenceResultSHA256','traffic'):
            _,x=fixture(0);_,y=fixture(1)
            if field=='traffic':y['receivedTensorBytes']+=2
            else:y['cases'][0][field]='f'*64
            with self.assertRaises(ValueError):validate_pair(x,y)
    def test_false_retirement_or_resource_floor_refused(self):
        for field,value in [('expertBanksReleased',False),('collectiveReleased',False),('nativeCacheBytesAfterRelease',1),('minimumActualFreeBytes',6*1024**3-1)]:
            j,v=fixture(0);v[field]=value
            with self.assertRaises(ValueError):validate_result(v,j)
    def test_job_geometry_and_extra_fields_refused(self):
        for change in ('extra','count','rank','lifetime'):
            j,_=fixture(0)
            if change=='extra':j['unreviewed']=True
            elif change=='count':j['nativeJob']['tokenCounts']=[34]
            elif change=='rank':j['nativeJob']['rank']=1
            else:j['timeoutSeconds']=301
            with self.assertRaises(ValueError):validate_job(j)
    def test_synthetic_job_cannot_activate_rdma(self):
        j,_=fixture(0);j['kind']='synthetic-small';j['mode']='full'
        with self.assertRaises(ValueError):validate_job(j)
if __name__=='__main__':unittest.main()
