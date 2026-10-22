"""Independent 16+16 ownership/refusal cases using invented state digests only."""
import copy
import unittest
from audit_common import PLAN, REFERENCE_PLAN
from audit_reference import check_reference
from audit_candidate import compare
from audit_state import state_fingerprint
from fabricated import fixture, reference_bytes

class PartitionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        _, cls.context, cls.admitted, cls.report, cls.expected, cls.candidates = fixture()
        cls.reference = check_reference(reference_bytes(cls.admitted, cls.report), cls.context)

    def test_fixed_reference_plan_different_from_candidate(self):
        self.assertNotEqual(PLAN, REFERENCE_PLAN)
        self.assertEqual(self.admitted['planSHA256'], REFERENCE_PLAN)
        self.assertEqual(self.expected['planFingerprint'], PLAN)
        result = compare(self.reference, self.candidates, self.expected, self.context)
        self.assertEqual(result['stageCut'], 16)
        self.assertEqual(result['stageStateEntryCounts'], [36, 36])
        self.assertEqual(result['orderedStateEntriesCompared'], 72)
        self.assertEqual([sum(x['byteCount'] for x in c['stateEntries']) for c in self.candidates], [162054160]*2)

    def test_cut4_ownership_cannot_be_relabelled_cut16(self):
        c = copy.deepcopy(self.candidates)
        all_entries = c[0]['stateEntries'] + c[1]['stateEntries']
        for rank, (start, end) in enumerate([(0, 4), (4, 32)]):
            c[rank]['stateEntries'] = [x for x in all_entries if start <= x['globalLayerIndex'] < end]
            c[rank]['logicalStateBytes'] = sum(x['byteCount'] for x in c[rank]['stateEntries'])
            c[rank]['stageStateSHA256'] = state_fingerprint(c[rank]['stateEntries'])
        with self.assertRaises(ValueError):
            compare(self.reference, c, self.expected, self.context)

    def test_rehashed_cross_rank_move_still_refused(self):
        c = copy.deepcopy(self.candidates)
        c[0]['stateEntries'].append(c[1]['stateEntries'].pop(0))
        for rank in range(2):
            c[rank]['logicalStateBytes'] = sum(x['byteCount'] for x in c[rank]['stateEntries'])
            c[rank]['stageStateSHA256'] = state_fingerprint(c[rank]['stateEntries'])
        with self.assertRaises(ValueError):
            compare(self.reference, c, self.expected, self.context)

    def test_candidate_plan_cannot_substitute_full_reference_provenance(self):
        a = copy.deepcopy(self.admitted)
        a['planSHA256'] = PLAN
        with self.assertRaises(ValueError):
            check_reference(reference_bytes(a, self.report), self.context)
        e = copy.deepcopy(self.expected)
        e['planFingerprint'] = REFERENCE_PLAN
        with self.assertRaises(ValueError):
            compare(self.reference, self.candidates, e, self.context)

if __name__ == '__main__':
    unittest.main()
