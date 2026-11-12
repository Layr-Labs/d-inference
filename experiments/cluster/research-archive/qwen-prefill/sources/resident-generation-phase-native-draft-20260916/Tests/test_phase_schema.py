"""Fabricated reports only. No native, remote or actual candidate inputs."""
import copy
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('phase', Path(__file__).resolve().parents[1] / 'validate_phase.py')
phase = importlib.util.module_from_spec(spec)
spec.loader.exec_module(phase)

def fixture(rank, policy):
    identity = dict(requestID='11111111-1111-4111-8111-111111111111',
        membershipEpoch='22222222-2222-4222-8222-222222222222', rank=rank,
        promptCount=8192, chunkSize=512, outputCount=128, prefillPolicy=policy)
    for key in ['requestFingerprint', 'agreementFingerprint', 'profileFingerprint',
        'sourceConfigurationSHA256', 'artifactAggregateSHA256', 'storageCommitmentSHA256',
        'planFingerprint', 'stageFingerprint', 'buildSHA256', 'numericalPolicySHA256']:
        identity[key] = 'a'*64
    budget = dict(maximumEvents=288, eventLogicalBytes=23040, eventAllocationBytes=32768,
        encodedResultAllocationBytes=266240, encodingScratchAllowanceBytes=528384, metadataAllowanceBytes=20480)
    budget['requiredHostReservationBytes'] = sum(budget[k] for k in ['eventAllocationBytes',
        'encodedResultAllocationBytes', 'encodingScratchAllowanceBytes', 'metadataAllowanceBytes'])
    budget['totalReservedBytes'] = budget['requiredHostReservationBytes'] + 1024*1024
    report = dict(schema='qwen_resident_generation_phase_report_v1', identity=identity,
        clockSource='dispatch_uptime_nanoseconds', protocolBoundary='resident_generation_send_completed_credit_v1',
        budget=budget, liveResourceChecksBeforeEncoding=10,
        execution=dict(completedFrames=143, committedTokens=8319, tokenChainSHA256='b'*64,
            finishReason='length', bothRequestStatesRetired=True, selectedTokenIDs=list(range(128))),
        events=[dict(event, ordinal=i, localUptimeNanoseconds=100+i) for i,event in enumerate(phase.expected_events(rank,policy))])
    report['firstLocalUptimeNanoseconds'] = report['events'][0]['localUptimeNanoseconds']
    report['lastLocalUptimeNanoseconds'] = report['events'][-1]['localUptimeNanoseconds']
    for key in ['diagnosticOnly','includesRecorderOverhead','modelRemainsResident']:
        report[key] = True
    for key in ['mtpEnabled','crossProcessClockAlignmentAsserted','gpuKernelTimeAsserted',
        'transportWaitIsWireCost','ownerLeaseRetirementIndependentlyVerified','independentNumericalComparisonPerformed','wholeProcessPeakBoundProved']:
        report[key] = False
    return report, dict(identity=copy.deepcopy(identity), expectedTokenIDs=list(range(128)))

class PhaseSchemaTests(unittest.TestCase):
    def test_four_exact_native_schedules(self):
        for rank in [0,1]:
            for policy in ['serial','oneChunkLookahead']:
                report, expected = fixture(rank,policy)
                result = phase.validate(report,expected)
                self.assertEqual(result['events'], 187 if rank == 0 and policy == 'serial' else 203)
                self.assertFalse(result['physicalCleanupValidated'])

    def test_lookahead_prepares_next_before_old_consumed_wait(self):
        report, expected = fixture(0,'oneChunkLookahead')
        rows=report['events']; prepare=next(i for i,x in enumerate(rows) if x['phase']=='prepareBegin' and x['frame']['sequence']==1)
        wait=next(i for i,x in enumerate(rows) if x['phase']=='consumedAckWaitBegin' and x['frame']['sequence']==0)
        self.assertLess(prepare,wait)
        rows[prepare],rows[wait]=rows[wait],rows[prepare]
        with self.assertRaises(ValueError): phase.validate(report,expected)

    def test_receiver_selection_follows_consumed_ack(self):
        report, expected = fixture(1,'serial'); rows=report['events']
        selection=next(i for i,x in enumerate(rows) if x['phase']=='selectionBegin')
        self.assertEqual(rows[selection-1]['phase'],'consumedAckSendEnd')
        rows[selection-1]['phase']='payloadSendEnd'
        with self.assertRaises(ValueError): phase.validate(report,expected)

    def test_identity_partial_resources_and_clock_refused(self):
        for mutation in ['identity','partial','resources','clock','bool','endpoint','expected']:
            report, expected=fixture(0,'serial')
            if mutation=='identity': report['identity']['buildSHA256']='c'*64
            if mutation=='partial': report['events'].pop()
            if mutation=='resources': report['budget']['requiredHostReservationBytes']-=1
            if mutation=='clock': report['events'][2]['localUptimeNanoseconds']=1
            if mutation=='bool': report['events'][1]['ordinal']=True
            if mutation=='endpoint': report['firstLocalUptimeNanoseconds']=100.0
            if mutation=='expected': expected['expectedTokenIDs'][0]=False
            with self.assertRaises(ValueError): phase.validate(report,expected)

if __name__ == '__main__': unittest.main()
