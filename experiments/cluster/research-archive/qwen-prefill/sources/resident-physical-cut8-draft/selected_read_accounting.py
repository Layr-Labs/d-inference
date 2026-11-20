"""Validate selected-read operations separately from the frozen tensor identity."""
import copy

from physical_common import exact, fields, integer, require

ALIGNMENT = 16384
SCRATCH = 8 * 1024**2
MAX_ALLOCATION = SCRATCH + ALIGNMENT
FIELD = 'selectedPayloadReadAccounting'
CONSTANTS = dict(schema='checkpoint_aligned_selected_read_v1', alignmentBytes=ALIGNMENT,
    maximumScratchAllocationBytes=MAX_ALLOCATION, cacheBypassRequested=True,
    readAheadDisabledRequested=True, fileCacheAbsenceEstablished=False)
COUNTERS = ('selectedBytes requestedReadBytes returnedReadBytes paddingReadBytes preadCalls '
    'interruptedCalls shortEOFReads largestScratchRequestBytes largestScratchAllocationBytes').split()


def ceiling(value, unit):
    return (value + unit - 1) // unit


def validated_load(actual, expected):
    require(type(actual) is dict and FIELD in actual, 'Aligned selected-read accounting missing')
    semantic = {key:value for key,value in actual.items() if key != FIELD}
    exact(semantic, expected, 'Selected tensor source identity differs')
    record = actual[FIELD]
    fields(record, ' '.join(CONSTANTS) + ' ' + ' '.join(COUNTERS), 'selected read accounting')
    for key, value in CONSTANTS.items():
        exact(record[key], value, 'Selected read policy ' + key)
    for key in COUNTERS:
        integer(record[key])
    sizes = [item['byteCount'] for item in expected['activeTensors']]
    require(sizes and sum(sizes) == expected['loadedTensorBytes'], 'Qualified active tensor bytes differ')
    require(record['selectedBytes'] == expected['loadedTensorBytes'], 'Selected read bytes differ')
    require(record['returnedReadBytes'] == record['selectedBytes'] + record['paddingReadBytes'],
            'Returned/selected/padding identity differs')
    require(record['paddingReadBytes'] <= 2 * (ALIGNMENT - 1) * len(sizes), 'Padding exceeds selected spans')
    successful = record['preadCalls'] - record['interruptedCalls']
    require(sum(ceiling(size, SCRATCH) for size in sizes) <= successful <=
            sum(ceiling(size + 2 * (ALIGNMENT - 1), SCRATCH) for size in sizes),
            'Successful read calls differ from whole-tensor spans')
    require(record['shortEOFReads'] <= min(successful, len(sizes)), 'EOF count exceeds selected spans')
    excess = record['requestedReadBytes'] - record['returnedReadBytes']
    require(record['requestedReadBytes'] % ALIGNMENT == 0 and
            record['interruptedCalls'] * ALIGNMENT + record['shortEOFReads'] <= excess <=
            record['interruptedCalls'] * SCRATCH + record['shortEOFReads'] * (ALIGNMENT - 1),
            'Requested/returned reads differ from interruptions and EOF')
    largest = record['largestScratchRequestBytes']
    require(largest == min(SCRATCH, max(ceiling(size, ALIGNMENT) * ALIGNMENT for size in sizes)),
            'Largest scratch request differs from selected tensors')
    require(largest <= record['largestScratchAllocationBytes'] <= largest + ALIGNMENT,
            'Actual scratch allocation exceeds admitted bound')
    return copy.deepcopy(actual)
