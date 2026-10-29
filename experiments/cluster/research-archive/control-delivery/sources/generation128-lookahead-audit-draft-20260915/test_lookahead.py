"""Fabricated lookahead records only; no retained candidate inputs."""
import copy
import unittest
from audit_common import agreement
from audit_reference import check_reference
from audit_candidate import compare
from fabricated import fixture, reference_bytes
from recorded_math import canonical, digest


class LookaheadTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        _, cls.context, admitted, report, cls.expected, cls.candidates = fixture()
        cls.reference = check_reference(reference_bytes(admitted, report), cls.context)

    def refuses(self, change):
        candidates = copy.deepcopy(self.candidates)
        change(candidates)
        with self.assertRaises(ValueError):
            compare(self.reference, candidates, self.expected, self.context)

    def test_complete_lookahead_retains_numerical_counts_and_limits(self):
        result = compare(self.reference, self.candidates, self.expected, self.context)
        self.assertEqual(result['expectedAgreement']['prefillSchedulingPolicy'], 'oneChunkLookahead')
        self.assertEqual((result['comparedSelectedTokenCount'], result['orderedStateEntriesCompared'],
                          result['finalNativeBF16RowBytesCompared']), (128, 72, 496640))
        for key in ('referenceIntermediateLogitHashesReconstructed', 'perTokenLogitComparisonPerformed',
                    'candidateIntermediateFrontiersIndependentlyVerified', 'tokenChainIndependentlyReconstructed',
                    'otherStateEntryBytesReconstructed', 'runtimeResourcePolicyReplayed',
                    'requestRetirementIndependentlyObserved', 'physicalTransferQualified',
                    'performanceQualification', 'throughputMeasurementValid', 'externalTTFTMeasured'):
            self.assertIs(result[key], False, key)

    def test_expected_agreement_must_explicitly_select_exact_native_policy(self):
        for value in (None, '', 'serial', 'serial_v1', 'one_chunk_lookahead_v1', True):
            with self.subTest(value=value):
                expected = copy.deepcopy(self.expected)
                expected['prefillSchedulingPolicy'] = value
                with self.assertRaises(ValueError):
                    agreement(expected, self.context)
        expected = copy.deepcopy(self.expected)
        del expected['prefillSchedulingPolicy']
        with self.assertRaises(ValueError):
            agreement(expected, self.context)

    def test_each_schedule_has_closed_keys_and_cannot_be_omitted(self):
        for rank in (0, 1):
            with self.subTest(rank=rank):
                self.refuses(lambda c: c[rank]['execution'].pop('prefillSchedule'))
                self.refuses(lambda c: c[rank]['execution'].__setitem__('prefillSchedule', None))
                self.refuses(lambda c: c[rank]['execution']['prefillSchedule'].__setitem__('extra', 0))
                for key in self.candidates[rank]['execution']['prefillSchedule']:
                    self.refuses(lambda c, k=key: c[rank]['execution']['prefillSchedule'].pop(k))

    def test_frontier_credit_decode_and_slot_counts_are_exact(self):
        for rank in (0, 1):
            expected = self.candidates[rank]['execution']['prefillSchedule']
            for key in ('preparedAheadFrames', 'maximumPreparedBoundaries',
                        'pendingConsumedAtCompletion', 'decodePrefetchCount'):
                for value in (-1, expected[key] + 1, bool(expected[key]), float(expected[key])):
                    with self.subTest(rank=rank, key=key, value=value):
                        self.refuses(lambda c, k=key, v=value: c[rank]['execution']['prefillSchedule'].__setitem__(k, v))

    def test_rank_and_policy_are_not_interchangeable(self):
        for rank in (0, 1):
            self.refuses(lambda c: c[rank]['execution']['prefillSchedule'].__setitem__('rank', 1 - rank))
            self.refuses(lambda c: c[rank]['execution']['prefillSchedule'].__setitem__('rank', bool(rank)))
            for value in ('serial', 'one_chunk_lookahead_v1', 'oneChunkLookahead ', None):
                self.refuses(lambda c, v=value: c[rank]['execution']['prefillSchedule'].__setitem__('policy', v))
        self.refuses(lambda c: c[0]['execution'].__setitem__('prefillSchedule', c[1]['execution']['prefillSchedule']))

    def test_serial_or_mixed_records_and_old_agreement_fingerprint_refuse(self):
        for rank in (0, 1):
            self.refuses(lambda c: c[rank]['agreement'].pop('prefillSchedulingPolicy'))
            self.refuses(lambda c: c[rank]['agreement'].__setitem__('prefillSchedulingPolicy', 'serial'))
        serial = copy.deepcopy(self.expected)
        del serial['prefillSchedulingPolicy']
        old_hash = digest(b'qwen-stage-generation-v1|agreement|' + canonical(serial))
        self.assertNotEqual(old_hash, agreement(self.expected, self.context))
        for rank in (0, 1):
            self.refuses(lambda c: c[rank]['execution'].__setitem__('agreementFingerprint', old_hash))


if __name__ == '__main__':
    unittest.main()
