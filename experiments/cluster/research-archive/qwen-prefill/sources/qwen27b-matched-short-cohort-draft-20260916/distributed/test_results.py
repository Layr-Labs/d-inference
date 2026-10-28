"""Fabricated clock/terminal cases; these are not model or performance measurements."""
import copy
import unittest
import uuid
from timing_results import validate_cohort, token_hash


def fixture():
    config=dict(warmupCount=1,measuredCount=1,promptTokenIDs=[1]*8192,expectedTokenIDs=[2]*128,
        chunkSize=512,outputCount=128,stopTokenIDs=[],membershipEpoch=str(uuid.uuid4()),
        cohortLabel='fabricated',policyLabel='serial_v1')
    pin='a'*64
    common=dict(configurationSHA256=pin,cohortLabel=config['cohortLabel'],policyLabel=config['policyLabel'],
        promptTokenIDsSHA256=token_hash(config['promptTokenIDs']),expectedTokenIDsSHA256=token_hash(config['expectedTokenIDs']))
    start=dict(common,schema='owner_timing_cohort_started_v1',membershipEpoch=config['membershipEpoch'])
    observations=[]
    for i,(first,decode) in enumerate([(50,20),(1,2)]):
        clock=100_000_000_000*(i+1)
        observations.append(dict(requestID=str(uuid.uuid4()),phase='warmup' if i==0 else 'measured',iteration=max(0,i-1),
            reserveBegan=clock-2,reserveCompleted=clock-1,startCalled=clock,firstToken=clock+first*10**9,
            finalToken=clock+(first+decode)*10**9,finishedCallback=clock+(first+decode)*10**9+1,
            retirementObserved=clock+(first+decode)*10**9+2,resourcesReleased=clock+(first+decode)*10**9+3,
            completed=True,sequenceGuardMatched=True,tokenIDs=config['expectedTokenIDs'][:],finishReason='length',
            firstTokenCount=1,finalTokenCount=128,bytesInUseAfterRelease=0,internalOwnerControlFirstTokenNanoseconds=first*10**9))
    final=dict(common,schema='owner_timing_cohort_result_v1',requests=observations,completed=True,
        nativeCleanupObserved=[True,True],ownerDeviceLeaseReleasedObserved=[True,True],
        clock='DispatchTime.uptimeNanoseconds.same_controller_process',
        summary=dict(complete=True,completeMeasuredCount=1,warmupsExcluded=True,
            measuredInternalOwnerControlFirstTokenNanoseconds=[10**9],medianInternalOwnerControlFirstTokenNanoseconds=10**9))
    lines=[start]+[dict(schema='owner_timing_request_v1',configurationSHA256=pin,observation=x) for x in observations]+[final]
    parent=dict(runCompletedAndAliasRestored=True,pinsUnchanged=True,controllerExitCode=0,
        nativeProcessesAbsent=True,journalsEmpty=True,localController=dict(reaped=True,groupAbsent=True),
        leaseExitCode=0,leaseFinal=[dict(restored=True)],monitors=[dict(exitCode=0,errors=[]),dict(exitCode=0,errors=[])])
    return config,pin,lines,parent


class TimingResults(unittest.TestCase):
    def test_numerators_and_warmup_exclusion(self):
        result=validate_cohort(*fixture())
        self.assertEqual(result['medianInternalFirstTokenSeconds'],1)
        self.assertEqual(result['medianPrefillTokensPerSecond'],8192)
        self.assertEqual(result['medianContinuationTokensPerSecond'],63.5)
        self.assertFalse(result['wholeControllerElapsedUsedAsThroughput'])
    def test_missing_request_and_failed_warmup(self):
        f=fixture();f[2].pop(1)
        with self.assertRaises(ValueError):validate_cohort(*f)
        f=fixture();f[2][1]['observation']['completed']=False
        with self.assertRaises(ValueError):validate_cohort(*f)
    def test_cleanup_proofs_remain_separate(self):
        for key in ('nativeCleanupObserved','ownerDeviceLeaseReleasedObserved'):
            f=fixture();f[2][-1][key][1]=False
            with self.assertRaises(ValueError):validate_cohort(*f)
        for key in ('nativeProcessesAbsent','journalsEmpty','pinsUnchanged','runCompletedAndAliasRestored'):
            f=fixture();f[3][key]=False
            with self.assertRaises(ValueError):validate_cohort(*f)
        f=fixture();f[3]['leaseFinal'][0]['restored']=False
        with self.assertRaises(ValueError):validate_cohort(*f)
        f=fixture();f[3]['monitors'][0]['errors']=['lost reader']
        with self.assertRaises(ValueError):validate_cohort(*f)
    def test_wrong_sequence_or_remaining_charge(self):
        for key,value in [('tokenIDs',[3]*128),('bytesInUseAfterRelease',1),('finishReason','stop')]:
            f=fixture();f[2][2]['observation'][key]=value
            with self.assertRaises(ValueError):validate_cohort(*f)
    def test_reused_request_and_config_pin(self):
        f=fixture();f[2][2]['observation']['requestID']=f[2][1]['observation']['requestID']
        with self.assertRaises(ValueError):validate_cohort(*f)
        f=fixture();f[2][2]['configurationSHA256']='b'*64
        with self.assertRaises(ValueError):validate_cohort(*f)
    def test_bad_clock_or_summary(self):
        for key,value in [('startCalled',True),('finalToken',0),('internalOwnerControlFirstTokenNanoseconds',1)]:
            f=fixture();f[2][2]['observation'][key]=value
            with self.assertRaises(ValueError):validate_cohort(*f)
        f=fixture();f[2][-1]['summary']['medianInternalOwnerControlFirstTokenNanoseconds']=1
        with self.assertRaises(ValueError):validate_cohort(*f)


class AggregateChecks(unittest.TestCase):
    def test_three_complete_and_failed_cohort_refusal(self):
        from aggregate import summarize
        rows=[fixture() for _ in range(3)]
        self.assertEqual(summarize(rows)['measuredCount'],3)
        rows[1][2][-1]['completed']=False
        with self.assertRaises(ValueError):summarize(rows)
        with self.assertRaises(ValueError):summarize(rows[:2])

    def test_reused_epoch_history_or_different_policy_refused(self):
        from aggregate import summarize
        rows=[fixture() for _ in range(3)]
        rows[1][0]['membershipEpoch']=rows[0][0]['membershipEpoch']
        rows[1][2][0]['membershipEpoch']=rows[0][0]['membershipEpoch']
        with self.assertRaises(ValueError):summarize(rows)
        rows=[fixture() for _ in range(3)]
        rows[1][2][1]['observation']['requestID']=rows[0][2][1]['observation']['requestID']
        with self.assertRaises(ValueError):summarize(rows)
        rows=[fixture() for _ in range(3)]
        rows[1][0]['policyLabel']='one_chunk_lookahead_v1'
        rows[1][2][0]['policyLabel']=rows[1][2][-1]['policyLabel']='one_chunk_lookahead_v1'
        with self.assertRaises(ValueError):summarize(rows)

if __name__=='__main__':unittest.main()

