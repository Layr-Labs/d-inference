"""Strict phase records reuse the final report's exact source/request checks."""
from binding_common import fields, integer, parse, require, same
from solo_contract import (measured_count, same_fields, validate_kernel,
                           validate_request, validate_source)


def loaded(raw, expected, first):
    require(0 < len(raw) <= 128*1024, 'Loaded progress bound')
    value = fields(parse(raw), 'kind schemaVersion verifiedFullModelLoads freshRequestStateCreated '
        'modelReleased cohortCompleted warmupCount measuredCount firstRequestID firstRequestFingerprint '
        'expectedTokenFileSHA256 source sourceLoad publishedNanoseconds', 'model loaded progress')
    same_fields(value, dict(kind='qwen_resident_solo_model_loaded', schemaVersion=1,
        verifiedFullModelLoads=1, freshRequestStateCreated=False, modelReleased=False,
        cohortCompleted=False, warmupCount=1, measuredCount=measured_count(expected),
        firstRequestID=first['requestIDs'][0], firstRequestFingerprint=first['requestFingerprints'][0],
        expectedTokenFileSHA256=expected.job['expected_sha256']))
    validate_source(value['source'], value['sourceLoad'], expected)
    integer(value['publishedNanoseconds'], 'loaded publication', 1, 2**64-1)
    return value


def retired(raw, expected, first, index, previous_publication):
    require(0 < len(raw) <= 128*1024, 'Retired progress bound')
    value = fields(parse(raw), 'kind schemaVersion modelReleased cohortCompleted warmupCount '
        'measuredCount expectedTokenFileSHA256 request kernelEligibility publishedNanoseconds', 'retired progress')
    same_fields(value, dict(kind='qwen_resident_solo_request_retired', schemaVersion=1,
        modelReleased=False, cohortCompleted=False, warmupCount=1,
        measuredCount=measured_count(expected), expectedTokenFileSHA256=expected.job['expected_sha256']))
    require(type(index) is int and 0 <= index < 1+measured_count(expected), 'Retired ordinal bound')
    start, end = validate_request(value['request'], expected, first, index)
    validate_kernel(value['kernelEligibility'])
    stamp = integer(value['publishedNanoseconds'], 'retired publication', 1, 2**64-1)
    require(previous_publication < start < end <= stamp, 'Publication must follow retirement and precede next timing')
    return value


def reconcile(final, model, rows):
    """Only a validated complete report may reconcile already-retained phase evidence."""
    same(final['source'], model['source'], 'Final source differs from loaded record')
    same(final['sourceLoad'], model['sourceLoad'], 'Final receipt differs from loaded record')
    same(final['requests'], [v['request'] for v in rows], 'Final requests differ from progressive records')
    require(rows and all(v['kernelEligibility'] == final['kernelEligibility'] for v in rows),
            'Final warmup eligibility differs from progressive records')
