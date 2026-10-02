"""Exact local result validator, with only required observed host changed to M4 Pro."""
import statistics

SHAPES = {'9b_prefill_bf16_c512': 4_194_304, '27b_prefill_bf16_c512': 5_242_880,
          '9b_decode_bf16': 8_192, '27b_decode_bf16': 10_240}


def validate_result(value):
    if value.get('schema') != 'darkbloom_authenticated_record_cpu_benchmark_v1':
        raise ValueError('Wrong CPU benchmark schema')
    if any(value.get(name) is not False for name in ['encryptedRDMAMeasured', 'modelMeasured', 'keysLogged']):
        raise ValueError('Unexpected scope claim')
    if value.get('hostChip') != 'Apple M4 Pro': raise ValueError('Wrong observed CPU identity')
    cases = value.get('cases')
    if not isinstance(cases, list) or len(cases) != 8: raise ValueError('Missing CPU cases')
    expected = {(name, rank) for name in SHAPES for rank in [0, 1]}
    seen = set(); summaries = []
    for case in cases:
        if type(case.get('sourceRank')) is not int: raise ValueError('Invalid rank type')
        key = (case.get('name'), case.get('sourceRank'))
        if key not in expected or key in seen: raise ValueError('Wrong/duplicate case')
        seen.add(key); size = SHAPES[key[0]]
        required = {'destinationRank': 1 - key[1], 'plaintextBytes': size, 'sealedBytes': size + 40,
            'warmupCount': 3, 'measuredCount': 20, 'verifiedPlaintextCount': 23,
            'sequenceStartsAt': 0, 'sequenceEndsAt': 22, 'sealedRecords': 23, 'openedRecords': 23,
            'sealedPlaintextBytes': size * 23, 'openedPlaintextBytes': size * 23}
        for field, wanted in required.items():
            if type(case.get(field)) is not int or case[field] != wanted: raise ValueError('Counter/geometry differs: ' + field)
        if case.get('freshSessionKeyGenerated') is not True or case.get('codecsInvalidatedAfterMeasurements') is not True:
            raise ValueError('Fresh-key/invalidation case incomplete')
        warmup, measured = case.get('warmup'), case.get('samples')
        if not isinstance(warmup, list) or not isinstance(measured, list) or len(warmup) != 3 or len(measured) != 20:
            raise ValueError('Missing warmup/measured samples')
        for ordinal, sample in enumerate(warmup + measured):
            for field, wanted in [('ordinal', ordinal), ('plaintextBytes', size), ('sealedBytes', size + 40)]:
                if type(sample.get(field)) is not int or sample[field] != wanted: raise ValueError('Sample identity differs')
            for field in ['sealNanoseconds', 'openNanoseconds', 'pairedNanoseconds', 'betweenCallsNanoseconds']:
                if type(sample.get(field)) is not int or sample[field] < 0: raise ValueError('Invalid clock delta')
            if sample['sealNanoseconds'] == 0 or sample['openNanoseconds'] == 0:
                raise ValueError('Zero operation delta')
            if sample['pairedNanoseconds'] != sample['sealNanoseconds'] + sample['openNanoseconds'] + sample['betweenCallsNanoseconds']:
                raise ValueError('Paired clock interval differs')
        summary = {'name': key[0], 'sourceRank': key[1], 'plaintextBytes': size, 'sealedBytes': size + 40}
        for phase in ['seal', 'open', 'paired']:
            values = [row[phase + 'Nanoseconds'] for row in measured]
            median = statistics.median(values)
            summary[phase] = {'medianNanoseconds': median, 'minimumNanoseconds': min(values),
                'maximumNanoseconds': max(values), 'plaintextMiBPerSecondAtMedian': size * 1e9 / median / (1024 * 1024)}
        summaries.append(summary)
    if seen != expected: raise ValueError('Case coverage differs')
    return summaries

