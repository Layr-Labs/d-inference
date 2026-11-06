import copy
import json
from pathlib import Path
import tempfile
import unittest
from audit_io import Inputs, parse
from audit_records import observations, resources, token_hash

CPU = Path('/Users/developer/DarkbloomDev/cluster-research/owner-cancellation-recovery-draft-20260915/records/checks-2.stdout')


def fixture(case):
    # Already-frozen actual-child CPU observations, never forthcoming hardware records.
    source = next(v for v in map(json.loads, CPU.read_text().splitlines()) if v.get('case') == case)
    a, b = copy.deepcopy(source['observations'])
    config = dict(cancellationCase=case, cancellationEpoch=a['membershipEpoch'], recoveryEpoch=b['membershipEpoch'],
        promptTokenIDs=[1]*8192, expectedTokenIDs=list(range(9, 137)), lifetimeSeconds=30, requestSeconds=10,
        beforeFirstDelayMilliseconds=150)
    pin = 'a'*64
    start = dict(schema='owner_cancellation_recovery_started_v1', configurationSHA256=pin,
        cancellationCase=case, cancellationEpoch=a['membershipEpoch'], recoveryEpoch=b['membershipEpoch'],
        promptTokenIDsSHA256=token_hash(config['promptTokenIDs']), expectedTokenIDsSHA256=token_hash(config['expectedTokenIDs']), nativeKernelPhaseObserved=False)
    rows = [start] + [dict(schema='owner_cancellation_request_v1', configurationSHA256=pin, observation=v) for v in [a,b]]
    final = dict(schema='owner_cancellation_recovery_result_v1', configurationSHA256=pin, cancellationCase=case,
        completed=True, requests=[a,b], freshPairAndMembershipRequired=True,
        clock='DispatchTime.uptimeNanoseconds.same_controller_process', nativeCleanupObserved=[True]*4,
        ownerDeviceLeaseReleasedObserved=[True]*4, elapsedControllerNanoseconds=b['ownerLeaseDrainCompleted']-a['startCalled']+10**9)
    for key in ['oldEpochReuseQualified', 'independentRemoteJournalObservation', 'nativeKernelPhaseObserved',
                'fullNumericalComparisonPerformed', 'externalTTFTMeasured', 'performanceQualification', 'providerCapacityUpdated']:
        final[key] = False
    rows.append(final)
    return config, rows, pin


def sample():
    return dict(schema='native_owner_resource_observation_v1', ordinal=0, startedMonotonicNS=1,
        completedMonotonicNS=2, actualFreeBytes=7*1024**3, admissible=True, acPower=True, pressureLevel=1,
        reportedSwapBytes='0.00', rawVMStat='page size of 16384 bytes\nPages free: 458752.\n',
        rawPower="Now drawing from 'AC Power'", rawMemory='1\ntotal = 0.00M used = 0.00M free = 0.00M')


class AuditCheck(unittest.TestCase):
    def test_both_selected_phases(self):
        for case, expected in [('startedBeforeFirstToken',0),('afterFirstDecode',2)]:
            self.assertEqual(observations(*fixture(case))['tokenCountAtCancel'], expected)

    def test_phase_charge_cleanup_mutations(self):
        mutations = [lambda c,r:r[1]['observation'].update(tokenCountAtCancel=1),
            lambda c,r:r[1]['observation'].update(finishReason='length'),
            lambda c,r:r[1]['observation'].update(retiredBeforeCancel=True),
            lambda c,r:r[1]['observation'].update(bytesAfterEarlyRelease=0),
            lambda c,r:r[1]['observation'].update(pairUnavailableAfterCancel=False),
            lambda c,r:r[1]['observation'].update(cancelCalled=r[1]['observation']['retirementObserved']+1),
            lambda c,r:r[1]['observation'].update(ownerLeaseReleaseObserved=[True,False]),
            lambda c,r:r[-1].update(nativeCleanupObserved=[1,1,1,1]),
            lambda c,r:r[-1].update(oldEpochReuseQualified=True)]
        for mutate in mutations:
            c,r,p=fixture('startedBeforeFirstToken'); mutate(c,r)
            with self.assertRaises(ValueError): observations(c,r,p)

    def test_recovery_identity_sequence_order(self):
        mutations = [lambda c,r:r[2]['observation'].update(membershipEpoch=c['cancellationEpoch']),
            lambda c,r:r[2]['observation'].update(requestID=r[1]['observation']['requestID']),
            lambda c,r:r[2]['observation'].update(startCalled=r[1]['observation']['ownerLeaseDrainCompleted']-1),
            lambda c,r:r[2]['observation'].update(tokenIDs=[9]*128),
            lambda c,r:r[2]['observation'].update(finishReason='clientStop'),
            lambda c,r:r[2]['observation'].update(cancelCalled=1),
            lambda c,r:r[2]['observation'].update(bytesAfterRelease=1),
            lambda c,r:r[2]['observation'].update(startCalled=True)]
        for mutate in mutations:
            c,r,p=fixture('afterFirstDecode'); mutate(c,r)
            with self.assertRaises(ValueError): observations(c,r,p)

    def test_published_history_not_replaced(self):
        c,r,p=fixture('startedBeforeFirstToken');r[-1]['requests']=copy.deepcopy(r[-1]['requests']);r[-1]['requests'][0]['tokenCountAtCancel']=2
        with self.assertRaises(ValueError):observations(c,r,p)
        c,r,p=fixture('startedBeforeFirstToken')
        with self.assertRaises(ValueError):observations(c,r[:2]+r[3:],p)

    def test_resource_raw_arithmetic(self):
        self.assertEqual(resources([sample()])['minimumActualFreeBytes'],7*1024**3)
        for key,value in [('actualFreeBytes',6*1024**3-1),('actualFreeBytes',True),('admissible',False),
                          ('acPower',False),('rawPower','Battery Power'),('reportedSwapBytes','1.00'),
                          ('pressureLevel',3),('rawMemory','1\nused = 1.00M'),('ordinal',1)]:
            row=sample();row[key]=value
            with self.assertRaises(ValueError):resources([row])

    def test_strict_json_and_file_bound(self):
        for raw in [b'{"a":1,"a":2}',b'{"x":NaN}',b'{"x":1e999}']:
            with self.assertRaises(ValueError):parse(raw)
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'x';path.write_bytes(b'{}\n');self.assertEqual(Inputs().lines(path),[{}])
            with self.assertRaises(ValueError):Inputs().raw(path,maximum=2)
            path.write_bytes(b'{}')
            with self.assertRaises(ValueError):Inputs().lines(path)
            link=Path(tmp)/'link';link.symlink_to(path)
            with self.assertRaises(OSError):Inputs().raw(link)


if __name__=='__main__':unittest.main()
