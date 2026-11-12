"""Synthetic source-join controls; no native, model or physical proof."""
import copy,hashlib,sys,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parent.parent))
import compare as c

class Join(unittest.TestCase):
    def test_matching_and_duplicate_identical_pin(self):
        path=Path('/retained/terminal.json');raw=b'{"status":"completed"}'
        row=dict(path=str(path),bytes=len(raw),sha256=hashlib.sha256(raw).hexdigest())
        pins=c.retained_map([row,dict(row)]);c.require_join(pins,path,raw)
    def test_conflicting_pin_refused(self):
        row=dict(path='/retained/terminal.json',bytes=3,sha256='a'*64)
        for key,value in [('bytes',4),('sha256','b'*64)]:
            wrong=dict(row);wrong[key]=value
            with self.assertRaises(ValueError):c.retained_map([row,wrong])
    def test_replacement_size_missing_and_noncanonical_pin_refused(self):
        path=Path('/retained/terminal.json');raw=b'one'
        pins=c.retained_map([dict(path=str(path),bytes=3,sha256=hashlib.sha256(raw).hexdigest())])
        for p,data in [(path,b'two'),(path,b'one\n'),(Path('/retained/other.json'),raw)]:
            with self.assertRaises(ValueError):c.require_join(pins,p,data)
        for row in [dict(path='relative',bytes=3,sha256='a'*64),dict(path=str(path),bytes=True,sha256='a'*64)]:
            with self.assertRaises(ValueError):c.retained_map([row])
    def test_wire_scope_matches_exact_native_delimiters(self):
        job=dict(requestIDs=['00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000002'],membershipEpoch='00000000-0000-0000-0000-000000000003')
        wrapper=dict(targetNativeSHA256='a'*64,assistantNativeSHA256='b'*64);requests=['c'*64,'d'*64]
        fields=['gemma4_mtp_pull_k2_v1',job['requestIDs'][1],job['membershipEpoch'],'a'*64,'b'*64,
            c.TARGET,c.ASSISTANT,c.EMBEDDING,'c'*64,'129','143']
        expected=hashlib.sha256(('\n'.join(fields)+'\n').encode()).hexdigest()
        self.assertEqual(c.wire_scope(job,wrapper,requests,1),expected)
        self.assertNotEqual(expected,hashlib.sha256('\n'.join(fields).encode()).hexdigest())
    def test_wire_scope_uses_first_resource_request_and_current_uuid(self):
        job=dict(requestIDs=['00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000002'],membershipEpoch='00000000-0000-0000-0000-000000000003')
        wrapper=dict(targetNativeSHA256='a'*64,assistantNativeSHA256='b'*64);requests=['c'*64,'d'*64]
        first=c.wire_scope(job,wrapper,requests,1)
        self.assertEqual(first,c.wire_scope(job,wrapper,['c'*64,'e'*64],1))
        self.assertNotEqual(first,c.wire_scope(job,wrapper,['f'*64,'d'*64],1))
        self.assertNotEqual(first,c.wire_scope(job,wrapper,requests,0))
        job['membershipEpoch']='00000000-0000-0000-0000-000000000004'
        self.assertNotEqual(first,c.wire_scope(job,wrapper,requests,1))
    def test_semantics_exclude_only_independently_bound_namespace(self):
        job=dict(schema='gemma4_resident_benchmark_v1',mode='full',promptCount=128,chunkSize=64,outputCount=16,
            cut=7,residualDType='bfloat16',prefillPolicy='serial',timeoutSeconds=300,
            requestIDs=['00000000-0000-0000-0000-'+str(i).zfill(12) for i in range(1,5)],
            membershipEpoch='00000000-0000-0000-0000-000000000005',metadataDirectory='/ordinary/metadata',
            promptFile='/ordinary/prompt',modelDirectory='/registered/model',promptFileSHA256='a'*64,
            buildIdentitySHA256='b'*64,captureEvidence=True,outputDirectory='/ordinary/output')
        other=copy.deepcopy(job);other.update(metadataDirectory='/remote/metadata',promptFile='/remote/prompt',captureEvidence=False)
        self.assertEqual(c.semantic(job),c.semantic(other))
        for key in ['modelDirectory','promptFileSHA256','buildIdentitySHA256']:
            wrong=copy.deepcopy(other);wrong[key]='different';self.assertNotEqual(c.semantic(job),c.semantic(wrong))
        other['chunkSize']=128
        with self.assertRaises(ValueError):c.semantic(other)

if __name__=='__main__':unittest.main()
