"""Synthetic CPU controls only. These fabricate no native or physical evidence."""
import copy,hashlib,json,sys,unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parent.parent
sys.path[:0]=[str(ROOT),str(ROOT/'package')]
from remote_mtp_contract import validate_inputs
from compare import completion_join
from gemma_inputs import REMOTE
from dense_contract import SUMMARY,target_summary,target_terms,metadata_policy,POLICY

def fixtures():
    run=REMOTE/'runs'/'fixture-target'
    job=dict(schema='gemma4_resident_benchmark_v1',mode='full',modelDirectory='/Users/developer/DarkbloomDev/models/Gemma4-26B',
        metadataDirectory=str(REMOTE/'metadata'),promptFile=str(REMOTE/'prompts/prompt-128.json'),promptFileSHA256='a'*64,
        outputDirectory=str(run/'sidecars'),buildIdentitySHA256='b'*64,requestIDs=['00000000-0000-0000-0000-'+str(i).zfill(12) for i in range(1,5)],
        membershipEpoch='00000000-0000-0000-0000-000000000005',promptCount=128,chunkSize=64,outputCount=16,cut=7,prefillPolicy='serial',timeoutSeconds=300,residualDType='bfloat16',captureEvidence=False)
    local=dict(schema='gemma4_local_mtp_cohort_job_v1',benchmarkJob=str(run/'job.json'),benchmarkJobSHA256='c'*64,
        assistantModelDirectory='/Users/developer/DarkbloomDev/models/Gemma4-26B-assistant-bb94eae1',assistantMetadataDirectory=str(REMOTE/'assistant-metadata'),
        maximumDraftTokens=2,captureEvidence=True)
    wrapper=dict(schema='gemma4_remote_mtp_cohort_job_v1',role='target',localMTPJob=str(run/'local-mtp.json'),localMTPJobSHA256='d'*64,
        targetNativeSHA256='b'*64,assistantNativeSHA256='b'*64,embeddingIdentitySHA256='45259723b22ef7d5c039213763eb57a0711bdc7e897ca112b58821b3d97827a4')
    return job,local,wrapper,run

def check(rows):return validate_inputs(rows[0],rows[1],rows[2],'c'*64,'d'*64,rows[3])

class Contract(unittest.TestCase):
    def test_only_exact_serial_head_policy_summary(self):
        target_summary(dict(SUMMARY))
        for field,value in [('policy','packed-head'),('expectedDenseModules',234),('expectedTiedHeads',2),('expectedTiedHeads',True),('gatheredOverrideEnabled',True),('singleRowOverrideEnabled',True),('wholeModelNumericsQualified',True)]:
            wrong=dict(SUMMARY);wrong[field]=value
            with self.assertRaises(ValueError):target_summary(wrong)
    def test_four_individually_admitted_head_rows(self):
        rows=[dict(name='prior'+str(i),logicalBytes=1,allocationBound=16384) for i in range(30)]
        rows += [dict(name='serialTargetHead:row'+str(i),logicalBytes=1048576,allocationBound=1064960) for i in range(4)]
        target_terms(rows)
        for wrong in [rows[:-1],rows+[dict(rows[-1])],rows[:30]+[dict(rows[-1])]*4]:
            with self.assertRaises(ValueError):target_terms(wrong)
        wrong=copy.deepcopy(rows);wrong[-1]['allocationBound']=1048575
        with self.assertRaises(ValueError):target_terms(wrong)
    def test_dense_metadata_budget_and_operation_policy(self):
        value=dict(targetProjectionPolicy=POLICY,targetExtraLogicalNativeBytes=43568162,targetExtraHostBytes=16809984)
        metadata_policy(value,dict(promptCount=128))
        for field,new in [('targetProjectionPolicy','ordinary'),('targetExtraLogicalNativeBytes',39373858),('targetExtraHostBytes',0)]:
            wrong=dict(value);wrong[field]=new
            with self.assertRaises(ValueError):metadata_policy(wrong,dict(promptCount=128))
    def test_exact_target_and_assistant(self):
        rows=fixtures();self.assertEqual(check(rows),'target');rows[2]['role']='assistant';self.assertEqual(check(rows),'assistant')
    def test_unknown_role_and_extra_fields(self):
        for field,value in [('role','stage1'),('arbitraryPolicy',True)]:
            rows=fixtures();rows[2][field]=value
            with self.assertRaises(ValueError):check(rows)
    def test_depth_chunk_and_output_closed(self):
        for which,field,value in [(1,'maximumDraftTokens',3),(0,'chunkSize',128),(0,'outputCount',128),(0,'captureEvidence',True),(0,'mode','stage1')]:
            rows=fixtures();rows[which][field]=value
            with self.assertRaises(ValueError):check(rows)
    def test_config_and_native_substitution(self):
        for field,value in [('targetNativeSHA256','f'*64),('assistantNativeSHA256','f'*64),('localMTPJobSHA256','f'*64),('embeddingIdentitySHA256','x'*64)]:
            rows=fixtures();rows[2][field]=value
            with self.assertRaises(ValueError):check(rows)
    def test_paths_and_repeated_request(self):
        for field,value in [('modelDirectory','/tmp/model'),('outputDirectory','/tmp/sidecars'),('promptFile','/tmp/prompt')]:
            rows=fixtures();rows[0][field]=value
            with self.assertRaises(ValueError):check(rows)
        rows=fixtures();rows[0]['requestIDs'][3]=rows[0]['requestIDs'][0]
        with self.assertRaises(ValueError):check(rows)
    def test_launch_collection_exact_join(self):
        raw=b'{"actual":"terminal-one"}\n';sha=hashlib.sha256(raw).hexdigest();remote=str(REMOTE/'runs'/'fixture-target')
        value=dict(status='completed',mode='target',run=remote,terminalSHA256=sha)
        completion_join(value,raw,remote,'target',sha)
    def test_replaced_terminal_cannot_join(self):
        first=b'one';second=b'two';sha=hashlib.sha256(first).hexdigest();remote='fixed'
        value=dict(status='completed',mode='target',run=remote,terminalSHA256=sha)
        with self.assertRaises(ValueError):completion_join(value,second,remote,'target',sha)
    def test_swapped_role_or_saved_receipt_cannot_join(self):
        raw=b'one';sha=hashlib.sha256(raw).hexdigest();value=dict(status='completed',mode='target',run='fixed',terminalSHA256=sha)
        with self.assertRaises(ValueError):completion_join(value,raw,'fixed','assistant',sha)
        with self.assertRaises(ValueError):completion_join(value,raw,'fixed','target','f'*64)
if __name__=='__main__':unittest.main()
