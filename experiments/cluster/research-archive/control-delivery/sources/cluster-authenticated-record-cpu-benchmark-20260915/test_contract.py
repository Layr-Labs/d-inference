"""Fabricated result-validator controls only; never a benchmark/performance run."""
import copy
import unittest
import run as target


def fixture():
    cases = []
    for name, size in target.SHAPES.items():
        for rank in [0, 1]:
            rows = [{'ordinal': i, 'plaintextBytes': size, 'sealedBytes': size + 40,
                'sealNanoseconds': 100, 'openNanoseconds': 200,
                'pairedNanoseconds': 310, 'betweenCallsNanoseconds': 10} for i in range(23)]
            cases.append({'name': name, 'sourceRank': rank, 'destinationRank': 1 - rank,
                'plaintextBytes': size, 'sealedBytes': size + 40, 'warmupCount': 3,
                'measuredCount': 20, 'verifiedPlaintextCount': 23, 'sequenceStartsAt': 0,
                'sequenceEndsAt': 22, 'sealedRecords': 23, 'openedRecords': 23,
                'sealedPlaintextBytes': size * 23, 'openedPlaintextBytes': size * 23,
                'freshSessionKeyGenerated': True, 'codecsInvalidatedAfterMeasurements': True,
                'warmup': rows[:3], 'samples': rows[3:]})
    return {'schema': 'darkbloom_authenticated_record_cpu_benchmark_v1',
        'hostChip': 'Apple M4 Max', 'encryptedRDMAMeasured': False,
        'modelMeasured': False, 'keysLogged': False, 'cases': cases}


class Contract(unittest.TestCase):
    def test_valid(self):
        values = target.validate_result(fixture())
        self.assertEqual(len(values), 8)
        self.assertEqual(values[0]['seal']['medianNanoseconds'], 100)
        self.assertEqual(values[0]['paired']['medianNanoseconds'], 310)

    def test_case_coverage(self):
        for change in ['missing', 'duplicate']:
            value = fixture()
            if change == 'missing': value['cases'].pop()
            else: value['cases'][-1] = copy.deepcopy(value['cases'][0])
            with self.assertRaises(ValueError): target.validate_result(value)

    def test_boolean_rank(self):
        value = fixture(); value['cases'][1]['sourceRank'] = True
        with self.assertRaises(ValueError): target.validate_result(value)

    def test_bad_count(self):
        for field in ['verifiedPlaintextCount', 'sealedRecords', 'openedRecords', 'sealedPlaintextBytes', 'sealedBytes']:
            value = fixture(); value['cases'][0][field] += 1
            with self.assertRaises(ValueError): target.validate_result(value)

    def test_missing_samples(self):
        for field in ['warmup', 'samples']:
            value = fixture(); value['cases'][0][field].pop()
            with self.assertRaises(ValueError): target.validate_result(value)

    def test_invalid_clock(self):
        for field, replacement in [('sealNanoseconds', 0), ('openNanoseconds', -1),
                                   ('pairedNanoseconds', 999), ('betweenCallsNanoseconds', True)]:
            value = fixture(); value['cases'][0]['samples'][0][field] = replacement
            with self.assertRaises(ValueError): target.validate_result(value)

    def test_ordinal_reset(self):
        value = fixture(); value['cases'][0]['samples'][0]['ordinal'] = 0
        with self.assertRaises(ValueError): target.validate_result(value)

    def test_scope_or_host_claim(self):
        for field in ['encryptedRDMAMeasured', 'modelMeasured', 'keysLogged', 'hostChip']:
            value = fixture(); value[field] = True
            with self.assertRaises(ValueError): target.validate_result(value)

    def test_freshness_or_invalidation(self):
        for field in ['freshSessionKeyGenerated', 'codecsInvalidatedAfterMeasurements']:
            value = fixture(); value['cases'][0][field] = False
            with self.assertRaises(ValueError): target.validate_result(value)


if __name__ == '__main__': unittest.main()
