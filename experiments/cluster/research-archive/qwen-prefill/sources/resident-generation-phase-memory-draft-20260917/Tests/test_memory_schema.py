"""Fabricated scalar/phase reports only; no actual model or remote input."""
import copy
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('phase_memory', Path(__file__).resolve().parents[1] / 'validate_phase_memory.py')
phase = importlib.util.module_from_spec(spec)
spec.loader.exec_module(phase)

def sample(rank, ordinal, point, stamp, reads=None, total=None):
    return dict(ordinal=ordinal, point=point, startedNanoseconds=stamp,
        osStartedNanoseconds=stamp+1, osCompletedNanoseconds=stamp+2, completedNanoseconds=stamp+3,
        physicalMemoryBytes=(24 if rank == 0 else 48)*1024**3, pageSizeBytes=16384,
        kernelFreePages=524288, freePages=524288, inactivePages=1, speculativePages=0,
        actualFreeBytes=8*1024**3, estimatedReclaimableBytes=8*1024**3+16384,
        pressureLevel=1, swapUsedBytes=0, activePages=1, wiredPages=1, purgeablePages=1,
        fileBackedPages=1, anonymousPages=1, compressorPages=1,
        activeBytes=1024, cacheBytes=0, peakBytes=2048, allocatorLimitBytes=12*1024**3,
        requiredActualFreeBytes=6*1024**3, requiredAllocatorBytes=2*1024**3,
        authorizedTensorCount=reads, selectedTensorCount=total)

def fixture(rank=0, policy='serial'):
    identity=dict(requestID='11111111-1111-4111-8111-111111111111',
        membershipEpoch='22222222-2222-4222-8222-222222222222', rank=rank,
        promptCount=8192, chunkSize=256, outputCount=128, prefillPolicy=policy)
    for key in ['requestFingerprint','agreementFingerprint','profileFingerprint',
        'sourceConfigurationSHA256','artifactAggregateSHA256','storageCommitmentSHA256',
        'planFingerprint','stageFingerprint','buildSHA256','numericalPolicySHA256']:
        identity[key]='a'*64
    budget=dict(maximumEvents=544,eventLogicalBytes=43520,eventAllocationBytes=65536,
        memoryLogicalBytes=102400,memoryAllocationBytes=131072,
        encodedResultAllocationBytes=1052672,encodingScratchAllowanceBytes=2101248,
        metadataAllowanceBytes=20480)
    budget['requiredHostReservationBytes']=sum(budget[k] for k in ['eventAllocationBytes',
        'memoryAllocationBytes','encodedResultAllocationBytes','encodingScratchAllowanceBytes','metadataAllowanceBytes'])
    budget['totalReservedBytes']=budget['requiredHostReservationBytes']+1024**2
    memory=dict(maximumSamples=320,minimumPeriodicIntervalNanoseconds=10**9,
        readyUptimeNanoseconds=1_000_000_020,sameProcessClockAsPhases=True,includesObserverOverhead=True,
        streamsSynchronizedForObservation=False,continuousOSPeakObserved=False,vmCategoriesAreDisjoint=False,
        preLoadSourceVerificationCovered=False,publicationAndModelReleaseCovered=False,
        allocatorPeakScope='process_cumulative_without_reset',samples=[
            sample(rank,0,'load',1,0,463 if rank==0 else 1384),
            sample(rank,1,'loadComplete',1_000_000_001,463 if rank==0 else 1384,463 if rank==0 else 1384),
            sample(rank,2,'loadedRequestGuard',1_000_000_011),sample(rank,3,'requestBegin',2_000_000_001),
            sample(rank,4,'requestLive',3_100_000_001),sample(rank,5,'requestRetired',4_000_000_001)])
    report=dict(schema='qwen_resident_generation_phase_memory_report_v1',identity=identity,
        clockSource='dispatch_uptime_nanoseconds',protocolBoundary='resident_generation_send_completed_credit_v1',
        budget=budget,memory=memory,liveResourceChecksBeforeEncoding=10,
        execution=dict(completedFrames=159,committedTokens=8319,tokenChainSHA256='b'*64,
            finishReason='length',bothRequestStatesRetired=True,selectedTokenIDs=list(range(128))),
        events=[dict(e,ordinal=i,localUptimeNanoseconds=3_000_000_000+i*1_000_000)
                for i,e in enumerate(phase.expected_events(rank,policy))])
    report['firstLocalUptimeNanoseconds']=report['events'][0]['localUptimeNanoseconds']
    report['lastLocalUptimeNanoseconds']=report['events'][-1]['localUptimeNanoseconds']
    for key in ['diagnosticOnly','includesRecorderOverhead','modelRemainsResident']:report[key]=True
    for key in ['mtpEnabled','crossProcessClockAlignmentAsserted','gpuKernelTimeAsserted','transportWaitIsWireCost',
        'ownerLeaseRetirementIndependentlyVerified','independentNumericalComparisonPerformed','wholeProcessPeakBoundProved']:
        report[key]=False
    return report,dict(identity=copy.deepcopy(identity),expectedTokenIDs=list(range(128)))

class MemorySchemaTests(unittest.TestCase):
    def test_four_schedules_and_local_interval_joins(self):
        for rank in (0,1):
            for policy in ('serial','oneChunkLookahead'):
                report,expected=fixture(rank,policy);result=phase.validate(report,expected)
                self.assertEqual(result['events'],363 if rank==0 and policy=='serial' else 395)
                self.assertEqual(result['memory']['sampleCount'],6)
                self.assertIsNone(result['memory']['sameProcessPhaseJoins'][0]['precedingPhaseOrdinal'])
                self.assertIsNotNone(result['memory']['sameProcessPhaseJoins'][4]['precedingPhaseOrdinal'])
                self.assertIsNone(result['memory']['sameProcessPhaseJoins'][-1]['followingPhaseOrdinal'])
                self.assertFalse(result['physicalCleanupValidated'])
                self.assertFalse(result['memory']['placementPermissionGranted'])

    def test_exact_phase_order_and_old_geometry_refused(self):
        for change in ('lookahead-order','receiver-order','C512','partial','target','clock','bool'):
            report,expected=fixture(0,'oneChunkLookahead');rows=report['events']
            if change=='lookahead-order':
                p=next(i for i,x in enumerate(rows) if x['phase']=='prepareBegin' and x['frame']['sequence']==1)
                w=next(i for i,x in enumerate(rows) if x['phase']=='consumedAckWaitBegin' and x['frame']['sequence']==0)
                self.assertLess(p,w);rows[p],rows[w]=rows[w],rows[p]
            if change=='receiver-order':
                report,expected=fixture(1);rows=report['events']
                i=next(i for i,x in enumerate(rows) if x['phase']=='selectionBegin')
                self.assertEqual(rows[i-1]['phase'],'consumedAckSendEnd');rows[i-1]['phase']='payloadSendEnd'
            if change=='C512':report['identity']['chunkSize']=expected['identity']['chunkSize']=512
            if change=='partial':rows.pop()
            if change=='target':report['execution']['selectedTokenIDs'][0]=999
            if change=='clock':rows[1]['localUptimeNanoseconds']=1
            if change=='bool':rows[1]['ordinal']=True
            with self.subTest(change=change),self.assertRaises(ValueError):phase.validate(report,expected)

    def test_os_arithmetic_and_actual_free_admission(self):
        for field,value in [('actualFreeBytes',1),('freePages',1),('kernelFreePages',1),
            ('estimatedReclaimableBytes',48*1024**3),('requiredActualFreeBytes',9*1024**3),
            ('requiredAllocatorBytes',13*1024**3),('swapUsedBytes',1),('pressureLevel',4),
            ('physicalMemoryBytes',48*1024**3),('pageSizeBytes',0),('activeBytes',True)]:
            report,expected=fixture();report['memory']['samples'][0][field]=value
            with self.subTest(field=field),self.assertRaises(ValueError):phase.validate(report,expected)

    def test_clock_brackets_cadence_and_native_peak(self):
        for change in ('bracket','period','peak','start','uint64'):
            report,expected=fixture();rows=report['memory']['samples']
            if change=='bracket':rows[0]['osCompletedNanoseconds']=rows[0]['completedNanoseconds']+1
            if change=='period':
                extra=sample(0,5,'requestLive',3_200_000_001);rows.insert(5,extra);rows[-1]['ordinal']=6
            if change=='peak':rows[-1]['peakBytes']=1024
            if change=='start':rows[1]['startedNanoseconds']=0
            if change=='uint64':rows[0]['completedNanoseconds']=2**64
            with self.subTest(change=change),self.assertRaises(ValueError):phase.validate(report,expected)

    def test_ready_retirement_and_phase_anchors(self):
        for change in ('ready','begin','retired','missing','sequence'):
            report,expected=fixture();rows=report['memory']['samples']
            if change=='ready':report['memory']['readyUptimeNanoseconds']=0
            if change=='begin':rows[3]=sample(0,3,'requestBegin',3_050_000_000)
            if change=='retired':rows[-1]=sample(0,5,'requestRetired',3_100_000_011)
            if change=='missing':rows.pop()
            if change=='sequence':rows[2]['point']='requestLive'
            with self.subTest(change=change),self.assertRaises(ValueError):phase.validate(report,expected)

    def test_progress_identity_and_named_host_charge(self):
        for change in ('initial','inventory','incomplete','request-count','host','memory','identity'):
            report,expected=fixture();rows=report['memory']['samples']
            if change=='initial':rows[0]['authorizedTensorCount']=1
            if change=='inventory':rows[1]['selectedTensorCount']=11
            if change=='incomplete':rows[1]['authorizedTensorCount']=9
            if change=='request-count':rows[-1]['authorizedTensorCount']=10
            if change=='host':report['budget']['requiredHostReservationBytes']-=1
            if change=='memory':report['budget']['memoryAllocationBytes']=1
            if change=='identity':report['identity']['buildSHA256']='c'*64
            with self.subTest(change=change),self.assertRaises(ValueError):phase.validate(report,expected)

    def test_claims_remain_explicitly_limited(self):
        for key in ['streamsSynchronizedForObservation','continuousOSPeakObserved','vmCategoriesAreDisjoint',
                    'preLoadSourceVerificationCovered','publicationAndModelReleaseCovered']:
            report,expected=fixture();report['memory'][key]=True
            with self.subTest(key=key),self.assertRaises(ValueError):phase.validate(report,expected)

    def test_collection_reader_refuses_duplicate_and_oversized_json(self):
        import tempfile
        with tempfile.TemporaryDirectory() as temporary:
            p=Path(temporary)/'report.json';p.write_bytes(b'{"a":1,"a":2}')
            with self.assertRaises(ValueError):phase.read(p,phase.CAP)
            p.write_bytes(b' '*(phase.CAP+1))
            with self.assertRaises(ValueError):phase.read(p,phase.CAP)

if __name__=='__main__':unittest.main()
