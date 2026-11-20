"""Synthetic CPU controls only. These fabricate no native or physical evidence."""
import ast,copy,hashlib,json,re,sys,unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parent.parent
sys.path[:0]=[str(ROOT),str(ROOT/'package')]
from remote_mtp_contract import validate_inputs,validate_result
from compare import completion_join
from gemma_inputs import REMOTE
from dense_contract import SUMMARY,target_summary,target_terms,metadata_policy,POLICY
from embedding_contract import NAMES,ARTIFACT,CONFIGURATION

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

def assistant_fixture():
    job,local,wrapper,_=fixtures();wrapper['role']='assistant'
    accounting=dict(schema='checkpoint_aligned_selected_read_v1',alignmentBytes=16384,
        maximumScratchAllocationBytes=8404992,cacheBypassRequested=True,readAheadDisabledRequested=True,
        fileCacheAbsenceEstablished=False,selectedBytes=415236096,requestedReadBytes=415285248,
        returnedReadBytes=415285248,paddingReadBytes=49152,preadCalls=51,interruptedCalls=0,
        shortEOFReads=0,largestScratchRequestBytes=8388608,largestScratchAllocationBytes=8404992)
    embedding=dict(artifactSHA256=ARTIFACT,configurationSHA256=CONFIGURATION,
        embeddingIdentitySHA256=wrapper['embeddingIdentitySHA256'],selectedNames=list(NAMES),
        selectedTensorCount=3,loadedTensorBytes=415236096,largestHostTensorBytes=369098752,
        readAccounting=accounting,resourceAdmissionEstablished=False)
    value=dict(schema='gemma4_remote_mtp_assistant_cohort_v1',configuration=wrapper,targetRank=1,assistantRank=0,
        warmupRequests=1,measuredRequests=3,modelReleased=True,nativeExecuted=True,collectiveCreated=True,
        collectiveReleased=True,encryptedRDMAEstablished=False,numericalComparisonPerformed=False,
        servingEnabled=False,physicalProcessOrLeaseRetirementEstablished=False,scopeSHA256='e'*64,
        nativeCacheBytesAfterRelease=0,guardObservationPolicy='gemma4_invocation_fresh_observation_v1',
        guardMetrics=dict(schema='gemma4_guard_wall_counters_v1'),fullTargetLoaded=False,
        assistantLoad=dict(artifactSHA256='d8c5fae1f4b7a07376c9f0b92f3ec283ba276d57ec3b675d8cf758a79d73bd34',
            tensorCount=94,tensorBytes=236114440,allActualParametersReplaced=True),embeddingLoad=embedding,
        resources=dict(placement='remoteAssistant',completedItems=97,observationCount=100,
            minimumActualFreeBytes=6*1024**3,servingFloorChanged=False,reclaimableUsedForAdmission=False),
        samples=[dict(ordinal=i,requestID=request,requestSHA256='f'*64,wireScopeSHA256='a'*64,
            originalServiceReleased=True,branchRootsReleased=True,targetTokensIndependentlyVerified=False,
            physicalOwnerRetirementEstablished=False) for i,request in enumerate(job['requestIDs'])])
    return value,job,local,wrapper

class Contract(unittest.TestCase):
    def test_every_executable_namespace_and_remote_body_agrees(self):
        from deploy import REMOTE as installed,INSTALL
        from remote_metadata import BODY
        self.assertEqual(installed,str(REMOTE))
        for body in [INSTALL,BODY]:
            tree=ast.parse(body)
            asserted=[node.value for statement in ast.walk(tree) if isinstance(statement,ast.Assert)
                for node in ast.walk(statement.test) if isinstance(node,ast.Constant)
                and isinstance(node.value,str) and node.value.startswith('/Users/developer/DarkbloomDev/gemma4-remote-mtp-')]
            self.assertEqual(asserted,[installed])
        manifest=json.loads((ROOT/'source-inputs.json').read_bytes())
        for row in manifest['members']:
            if row['path'].endswith('.py'):
                literals=re.findall(r'/Users/developer/DarkbloomDev/gemma4-remote-mtp-[A-Za-z0-9-]+',(ROOT/row['path']).read_text())
                self.assertTrue(all(value==installed for value in literals),row['path'])
    def test_assistant_final_completion_is_97_not_intermediate_94(self):
        rows=assistant_fixture();validate_result(*rows)
        for count in [94,96,98,True,97.0]:
            rows=assistant_fixture();rows[0]['resources']['completedItems']=count
            with self.assertRaises(ValueError):validate_result(*rows)
    def test_embedding_identity_substitution_is_refused(self):
        for field in ['artifactSHA256','configurationSHA256','embeddingIdentitySHA256']:
            rows=assistant_fixture();rows[0]['embeddingLoad'][field]='f'*64
            with self.assertRaises(ValueError):validate_result(*rows)
    def test_embedding_exact_selected_tensor_coverage(self):
        for field,value in [('selectedNames',list(reversed(NAMES))),('selectedNames',NAMES[:2]),
            ('selectedNames',[NAMES[0]]*3),('selectedTensorCount',2),('selectedTensorCount',True),
            ('loadedTensorBytes',415236095),('largestHostTensorBytes',23068672)]:
            rows=assistant_fixture();rows[0]['embeddingLoad'][field]=value
            with self.assertRaises(ValueError):validate_result(*rows)
    def test_embedding_read_policy_and_counters(self):
        for field,value in [('schema','unqualified'),('selectedBytes',236114440),('selectedBytes',True),
            ('requestedReadBytes',415236095),('returnedReadBytes',415236095),('paddingReadBytes',0),
            ('preadCalls',0),('interruptedCalls',52),('shortEOFReads',52),('alignmentBytes',4096),
            ('maximumScratchAllocationBytes',16777216),('largestScratchRequestBytes',8388609),
            ('largestScratchAllocationBytes',8404993),('cacheBypassRequested',False),
            ('readAheadDisabledRequested',False),('fileCacheAbsenceEstablished',True)]:
            rows=assistant_fixture();rows[0]['embeddingLoad']['readAccounting'][field]=value
            with self.assertRaises(ValueError):validate_result(*rows)
    def test_embedding_missing_receipt_or_unearned_admission(self):
        rows=assistant_fixture();del rows[0]['embeddingLoad']
        with self.assertRaises(ValueError):validate_result(*rows)
        for field,value in [('resourceAdmissionEstablished',True),('unknown',False)]:
            rows=assistant_fixture();rows[0]['embeddingLoad'][field]=value
            with self.assertRaises(ValueError):validate_result(*rows)
        rows=assistant_fixture();rows[0]['embeddingLoad']['readAccounting']['unknown']=0
        with self.assertRaises(ValueError):validate_result(*rows)
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
