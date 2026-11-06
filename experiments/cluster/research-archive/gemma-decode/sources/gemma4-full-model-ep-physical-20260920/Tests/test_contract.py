"""Pure transcript controls; never launches a process or reads model payloads."""
import copy
from pathlib import Path
import sys
import unittest
ROOT=Path(__file__).resolve().parents[1]
sys.dont_write_bytecode=True;sys.path.insert(0,str(ROOT/'Comparison'))
from expert_report import exchange_records
from recorded_math import canonical,digest

def fixture():
    h='a'*64;request='00000000-0000-4000-8000-000000000001';epoch='00000000-0000-4000-8000-000000000002'
    ids=[list(range(32)),list(range(32,128))]
    description=dict(original=dict(requestID=request,membershipEpoch=epoch,requestSHA256=h),
        globalExpertIDsByRank=ids,ownershipSHA256=digest(canonical(ids)),rankBuildSHA256=[h,h])
    records=[];total=0
    for purpose,frames in [('probe',[(0,'prefill',0,2,True),(1,'decode',2,1,False)]),
                           ('request',[(0,'prefill',0,16,False),(1,'prefill',16,16,True),(2,'decode',32,1,False)])]:
        for seq,phase,offset,count,final in frames:
            for layer in range(30):
                from contract import ARTIFACT,CONFIGURATION
                scope=dict(binding=dict(purpose=purpose,requestID=request.upper(),membershipEpoch=epoch.upper(),
                    requestSHA256=h,artifactSHA256=ARTIFACT,configurationSHA256=CONFIGURATION,
                    rankBuildSHA256=[h,h],ownershipSHA256=description['ownershipSHA256']),
                    frame=dict(sequence=seq,phase=phase,tokenOffset=offset,tokenCount=count,finalPromptChunk=final),
                    globalLayer=layer,tokenCount=count,dtype='bfloat16',routeSHA256=h,inputSHA256=h,weightsSHA256=h,
                    assignmentCounts=[count*4,count*4],projectionPolicies=[dict(globalAssignments=count*8,
                        globalExperts=128,ownedExperts=len(ids[r]),localAssignments=count*4,sortAssignments=count*8>=64,
                        sortedProjection=False,executedAssignments=count*4) for r in range(2)])
                records.append(dict(scope=scope,scopeSHA256=digest(canonical(scope)),rank0OutputSHA256=h,rank1OutputSHA256=h))
                total+=count*4*2816*2
    return dict(exchangeObservations=records,controlRecordsSent=607,controlRecordsReceived=607,
        sentTensorBytes=total,receivedTensorBytes=total),description

class TranscriptControls(unittest.TestCase):
    def test_complete_both_ranks(self):
        value,description=fixture()
        for rank in (1,2):exchange_records(value,description,rank)
    def test_missing_layer(self):
        value,description=fixture();value['exchangeObservations'].pop()
        with self.assertRaises(ValueError):exchange_records(value,description,1)
    def test_wrong_order(self):
        value,description=fixture();value['exchangeObservations'][0:2]=list(reversed(value['exchangeObservations'][0:2]))
        with self.assertRaises(ValueError):exchange_records(value,description,1)
    def test_frame_or_dtype(self):
        for key,bad in [('tokenCount',17),('dtype','float32')]:
            value,description=fixture();scope=value['exchangeObservations'][0]['scope'];scope[key]=bad
            with self.assertRaises(ValueError):exchange_records(value,description,1)
    def test_unjoined_epoch(self):
        value,description=fixture();value['exchangeObservations'][0]['scope']['binding']['membershipEpoch']=str(__import__('uuid').UUID(int=3))
        with self.assertRaises(ValueError):exchange_records(value,description,1)
    def test_padding_not_wire_rows(self):
        value,description=fixture();value['exchangeObservations'][0]['scope']['projectionPolicies'][0]['executedAssignments']+=1
        with self.assertRaises(ValueError):exchange_records(value,description,1)
    def test_complete_control_count(self):
        value,description=fixture();value['controlRecordsReceived']-=1
        with self.assertRaises(ValueError):exchange_records(value,description,1)
    def test_actual_payload_bytes(self):
        value,description=fixture();value['sentTensorBytes']+=2
        with self.assertRaises(ValueError):exchange_records(value,description,1)

if __name__=='__main__':unittest.main()
