"""Small CPU refusal controls. Staged only; no model or retained cohort reads."""
import copy
import unittest
from compare import binding, digest, logical_bytes, ordinary_scope, request_hash, state, workload


class Contracts(unittest.TestCase):
    def job(self):
        return dict(schema='gemma4_resident_benchmark_v1',mode='full',promptCount=128,chunkSize=64,
            outputCount=16,cut=7,residualDType='bfloat16',prefillPolicy='serial',timeoutSeconds=300,
            requestIDs=['00000000-0000-0000-0000-00000000000'+str(i) for i in range(4)],
            membershipEpoch='00000000-0000-0000-0000-000000000009',captureEvidence=True,
            outputDirectory='/evidence/a',buildIdentitySHA256='a'*64,promptFileSHA256='b'*64)

    def test_capture_and_independent_request_ids_do_not_change_math(self):
        a=self.job(); b=copy.deepcopy(a); b['captureEvidence']=False; b['outputDirectory']='/evidence/b'
        b['requestIDs']=[x.replace('00000000-','10000000-',1) for x in a['requestIDs']]
        self.assertEqual(workload(a),workload(b))

    def test_other_build_does_change_matched_workload(self):
        a=self.job(); b=copy.deepcopy(a); b['buildIdentitySHA256']='c'*64
        self.assertNotEqual(workload(a),workload(b))

    def test_long_context_and_changed_chunk_refused(self):
        for key,value in [('promptCount',4096),('chunkSize',128),('cut',8),('outputCount',128)]:
            job=self.job(); job[key]=value
            with self.assertRaises(ValueError): workload(job)

    def test_request_hash_joins_actual_uuid_and_prompt(self):
        job=self.job(); prompt=list(range(128))
        first=request_hash(job,0,prompt)
        self.assertNotEqual(first,request_hash(job,1,prompt))
        self.assertNotEqual(first,request_hash(job,0,prompt[:-1]+[200]))

    def test_scope_capture_policy_remains_distinct(self):
        job=self.job(); requests=[request_hash(job,i,list(range(128))) for i in range(4)]
        first=ordinary_scope(job,'d'*64,requests); job['captureEvidence']=False
        self.assertNotEqual(first,ordinary_scope(job,'d'*64,requests))

    def test_missing_and_duplicate_state_domain_refused_before_bytes(self):
        class NoReads:
            def read(self,_): raise AssertionError('Malformed state must refuse before payload read')
        bind={'stateLayoutSHA256':'a'*64,'layers':[]}
        with self.assertRaises(ValueError): state(dict(frontier=143,fingerprint='b'*64,entries=[]),bind,NoReads(),0)
        entry=dict(localLayerIndex=0,globalLayerIndex=0,component='kv.values',dtype='bfloat16',sha256='c'*64,
                   shape=[1,8,143,256],byteCount=585728,logicalRange=[0,143],file={})
        with self.assertRaises(ValueError): state(dict(frontier=143,fingerprint='b'*64,entries=[entry]*90),bind,NoReads(),0)

    def test_native_signed_zero_not_hidden_by_json_equality(self):
        positive=dict(shape=[1,1],dtype='bfloat16',byteCount=2,logicalBytesSHA256=digest(b'\0\0'),values=[0.0])
        negative=dict(positive,logicalBytesSHA256=digest(b'\0\x80'),values=[-0.0])
        self.assertNotEqual(logical_bytes(positive,1,'bfloat16'),logical_bytes(negative,1,'bfloat16'))
        with self.assertRaises(ValueError): logical_bytes(dict(negative,values=[0.0]),1,'bfloat16')

    def test_truncated_row_and_unknown_dtype_refused(self):
        row=dict(shape=[1,2],dtype='bfloat16',byteCount=4,logicalBytesSHA256='a'*64,values=[0])
        with self.assertRaises(ValueError): logical_bytes(row,2,'bfloat16')
        with self.assertRaises(ValueError): logical_bytes(dict(row,dtype='float64'),2,'float64')


if __name__=='__main__': unittest.main()
