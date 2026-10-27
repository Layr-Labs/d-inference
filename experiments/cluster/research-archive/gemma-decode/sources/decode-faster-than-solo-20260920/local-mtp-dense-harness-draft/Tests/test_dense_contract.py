import copy
import sys
import unittest
from pathlib import Path

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'proposed/package'))
# The original package helper is pinned by base-inputs/source manifest.
sys.path.append(str(Path(__file__).resolve().parents[2]/'harness-local-mtp-bound-memo/package'))
from local_mtp_contract import POLICY,validate_dense_metadata,text_hash

class DenseContractTests(unittest.TestCase):
    def fixture(self,depth=2,qualify=False):
        config=dict(benchmarkJobSHA256='a'*64,maximumDraftTokens=depth,captureEvidence=True)
        operation='qualify-mtp-conditioning-dense' if qualify else 'execute-local-mtp-dense'
        config_sha='b'*64
        value=dict(denseProjection=dict(policy=POLICY,expectedDenseModules=235,expectedTiedHeads=1,
            serialHeadLogicalBytes=4194304,gatheredOverrideEnabled=False,singleRowOverrideEnabled=False,
            wholeModelNumericsQualified=False),auxiliaryResources=dict(liveNativeReserveBytes=500000000,
                serialTargetHeadTerms=[dict(name='serialTargetHead:row'+str(i),logicalBytes=1048576,allocationBound=1048704) for i in range(4)]),
            ordinaryInputScopeSHA256='c'*64,assistantLoad=dict(artifactSHA256='d'*64,parameterLayoutSHA256='e'*64),
            samples=[dict(generation=dict(requestSHA256=str(i)*64)) for i in range(4)])
        scope=text_hash(['gemma4-local-mtp-cohort-v1',config_sha,'a'*64,'c'*64,'d'*64,'e'*64,
            'maximumDraftTokens='+str(depth),'captureEvidence=true','qualifyConditioning='+str(qualify).lower(),
            'mtp=true','remote=false']+[str(i)*64 for i in range(4)]+['targetProjection='+POLICY])
        value['scopeSHA256']=scope
        for i,sample in enumerate(value['samples']):sample['scopeSHA256']=text_hash([scope,'iteration='+str(i),str(i)*64])
        return value,config,config_sha,operation
    def reject(self,change):
        args=list(self.fixture());change(args)
        with self.assertRaises((AssertionError,ValueError,RuntimeError,KeyError)):
            validate_dense_metadata(*args)
    def test_depth_one_and_two(self):
        for depth in (1,2):validate_dense_metadata(*self.fixture(depth))
    def test_conditioning_scope(self):validate_dense_metadata(*self.fixture(2,True))
    def test_bool_is_not_head_count(self):self.reject(lambda a:a[0]['denseProjection'].__setitem__('expectedTiedHeads',True))
    def test_number_is_not_false(self):self.reject(lambda a:a[0]['denseProjection'].__setitem__('gatheredOverrideEnabled',0))
    def test_missing_head_row(self):self.reject(lambda a:a[0]['auxiliaryResources']['serialTargetHeadTerms'].pop())
    def test_duplicate_row_name(self):self.reject(lambda a:a[0]['auxiliaryResources']['serialTargetHeadTerms'][3].__setitem__('name','serialTargetHead:row0'))
    def test_underrounded_row(self):self.reject(lambda a:a[0]['auxiliaryResources']['serialTargetHeadTerms'][0].__setitem__('allocationBound',1048575))
    def test_only_head_reserve(self):self.reject(lambda a:a[0]['auxiliaryResources'].__setitem__('liveNativeReserveBytes',4*1048704))
    def test_policy_omitted_from_scope(self):self.reject(lambda a:a[0].__setitem__('scopeSHA256','f'*64))
    def test_changed_request_scope(self):self.reject(lambda a:a[0]['samples'][1].__setitem__('scopeSHA256','f'*64))
    def test_unselected_operation(self):self.reject(lambda a:a.__setitem__(3,'execute-local-mtp'))

if __name__=='__main__':unittest.main()
