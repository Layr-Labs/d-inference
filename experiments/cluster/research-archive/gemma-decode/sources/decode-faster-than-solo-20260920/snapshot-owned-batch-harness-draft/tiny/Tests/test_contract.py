"""Synthetic CPU controls only. These fabricate no native or physical evidence."""
import ast,re,copy,hashlib,json,sys,unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parent.parent
sys.path[:0]=[str(ROOT),str(ROOT/'package')]
from remote_mtp_contract import validate_inputs
from compare import completion_join
from gemma_inputs import REMOTE

def fixtures():
    run=REMOTE/'runs'/'fixture-target'
    job=dict(schema='gemma4_resident_benchmark_v1',mode='full',modelDirectory='/Users/developer/DarkbloomDev/models/Gemma4-26B',
        metadataDirectory=str(REMOTE/'metadata'),promptFile=str(REMOTE/'prompts/prompt-128.json'),promptFileSHA256='a'*64,
        outputDirectory=str(run/'sidecars'),buildIdentitySHA256='b'*64,requestIDs=['00000000-0000-0000-0000-'+str(i).zfill(12) for i in range(1,5)],
        membershipEpoch='00000000-0000-0000-0000-000000000005',promptCount=128,chunkSize=64,outputCount=16,cut=7,prefillPolicy='serial',timeoutSeconds=300,residualDType='bfloat16',captureEvidence=False)
    local=dict(schema='gemma4_local_mtp_cohort_job_v1',benchmarkJob=str(run/'job.json'),benchmarkJobSHA256='c'*64,
        assistantModelDirectory='/Users/developer/DarkbloomDev/models/Gemma4-26B-assistant-bb94eae1',assistantMetadataDirectory=str(REMOTE/'assistant-metadata'),
        maximumDraftTokens=2,captureEvidence=False)
    wrapper=dict(schema='gemma4_remote_mtp_cohort_job_v1',snapshotPolicy='gemma4_owned_snapshot_batch_gpu_boundaries_v1',role='target',localMTPJob=str(run/'local-mtp.json'),localMTPJobSHA256='d'*64,
        targetNativeSHA256='b'*64,assistantNativeSHA256='b'*64,embeddingIdentitySHA256='45259723b22ef7d5c039213763eb57a0711bdc7e897ca112b58821b3d97827a4')
    return job,local,wrapper,run

def check(rows):return validate_inputs(rows[0],rows[1],rows[2],'c'*64,'d'*64,rows[3])

def tiny_fixture():
    from pull_qualification_contract import GROUPS
    job,local,wrapper,_=fixtures()
    v=dict(schema='gemma4_remote_mtp_owned_batch_qualification_v1',configuration=wrapper,role='target',rank=1,
        groups=GROUPS,groupCount=5,snapshotFrontiers=[3,1031,3],completedSnapshotTransfers=21,receiverRetainedRootLimit=9,
        queuedAcknowledgements=2,completedPulls=1,cancelledUnpulledProposals=2,nativeReserveBytes=128*1024**2,
        hostReserveBytes=2*1024**2,minimumActualFreeBytes=11*1024**3,peakExtraActiveBytes=1024,resourceObservations=10,
        nativeCacheBytesAfterRelease=0,guardObservationPolicy='gemma4_invocation_fresh_observation_v1',
        guardMetrics=dict(schema='gemma4_guard_wall_counters_v1'),snapshotTransferPolicy=wrapper['snapshotPolicy'],
        hiddenDTypesQualified=['bfloat16','float16','float32'],perSnapshotTransferCount=7,perSnapshotCheckedBoundaryCount=2)
    for key in ['passed','staleSequenceRefused','nonzeroPaddingRefused','poisonedChannelReuseRefused','injectedPostReceiveCheckFailure',
        'nativeExecuted','jacclExecuted','allFixtureRootsRetired','collectiveCreated','collectiveReleased',
        'injectedPreassemblyCheckFailure','noncontiguousFullHeadProducers']:v[key]=True
    for key in ['actualGPUFaultInjected','gemmaWeightsExecuted','assistantWeightsExecuted','targetForwardExecuted','realAssistantProposalExecuted',
        'throughputMeasured','numericalComparisonPerformed','servingEnabled','encryptedRDMAEstablished','originalProcessRetirementEstablished','wholeProcessPeakBoundEstablished']:v[key]=False
    return v,job,local,wrapper

class Contract(unittest.TestCase):
    def test_exact_target_and_assistant(self):
        rows=fixtures();self.assertEqual(check(rows),'target');rows[2]['role']='assistant';self.assertEqual(check(rows),'assistant')
    def test_unknown_role_and_extra_fields(self):
        for field,value in [('role','stage1'),('arbitraryPolicy',True)]:
            rows=fixtures();rows[2][field]=value
            with self.assertRaises(ValueError):check(rows)
    def test_depth_chunk_and_output_closed(self):
        for which,field,value in [(1,'maximumDraftTokens',3),(1,'captureEvidence',True),(0,'promptCount',4096),(0,'chunkSize',128),(0,'outputCount',128),(0,'captureEvidence',True),(0,'mode','stage1')]:
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
    def test_only_explicit_batch_policy_without_other_experiments(self):
        for value in [None,'', 'gemma4_snapshot_per_tensor_v1', 'gemma4_owned_snapshot_batch_gpu_boundaries_v1 ']:
            rows=fixtures()
            if value is None:del rows[2]['snapshotPolicy']
            else:rows[2]['snapshotPolicy']=value
            with self.assertRaises(ValueError):check(rows)
        for field in ['refillPolicy','seedFillPolicy','continuationPolicy']:
            rows=fixtures();rows[2][field]='some-experiment'
            with self.assertRaises(ValueError):check(rows)
    def test_owned_batch_namespace_is_exact_inside_executable_bodies(self):
        from deploy import REMOTE as installed,INSTALL
        from remote_metadata import BODY
        self.assertEqual(installed,str(REMOTE))
        for body in [INSTALL,BODY]:
            tree=ast.parse(body)
            values=[n.value for statement in ast.walk(tree) if isinstance(statement,ast.Assert)
                for n in ast.walk(statement.test) if isinstance(n,ast.Constant) and isinstance(n.value,str)
                and n.value.startswith('/Users/developer/DarkbloomDev/gemma4-remote-mtp-')]
            self.assertEqual(values,[installed])
    def test_exact_batch_tiny_result_requires_new_native_path(self):
        from pull_qualification_contract import validate_result
        validate_result(*tiny_fixture())
        for field,value in [('schema','gemma4_remote_mtp_pull_qualification_v1'),('snapshotTransferPolicy','legacy'),
            ('hiddenDTypesQualified',['bfloat16']),('noncontiguousFullHeadProducers',False),('injectedPreassemblyCheckFailure',False)]:
            rows=tiny_fixture();rows[0][field]=value
            with self.assertRaises(ValueError):validate_result(*rows)
    def test_tiny_boundary_counts_and_native_claims_are_closed(self):
        from pull_qualification_contract import validate_result
        for field,value in [('perSnapshotTransferCount',6),('perSnapshotTransferCount',True),('perSnapshotCheckedBoundaryCount',7),
            ('actualGPUFaultInjected',True),('minimumActualFreeBytes',9*1024**3),('allFixtureRootsRetired',False)]:
            rows=tiny_fixture();rows[0][field]=value
            with self.assertRaises(ValueError):validate_result(*rows)
if __name__=='__main__':unittest.main()
