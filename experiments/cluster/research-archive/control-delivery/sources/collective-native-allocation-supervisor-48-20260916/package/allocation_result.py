"""Strict fixed-catalog allocation report replay; no native execution or approval."""
from functools import lru_cache
import hashlib
from pathlib import Path
from binding_common import fields, integer, parse, require, same, text

SCHEDULE = parse((Path(__file__).parent/'PROBE-SCHEDULE.json').read_bytes())
CASES = {row['id']: row for row in SCHEDULE['cases']}
require(len(CASES) == SCHEDULE['count'] == 35, 'Fixed allocation catalog differs')
MAXIMUM = 10_485_760
REPORT_KEYS = '''schema scope profileQualified caseID failureMode hardwareModel osBuild suite allocatorPolicy
maximumPlaintextBytes maximumFrameBytes maximumInFlightOperations rounds geometries elapsedNanoseconds
baselineNativeActiveBytes observedPeakNativeActiveBytes maximumObservedNativeCacheBytes finalNativeActiveBytes
finalNativeCacheBytes baselinePhysical finalPhysical conservativeObservedPhysicalIncrementBytes sentRecords
openedRecords publishedArrays refusedRecords frameLengths plaintextByteCounts actualInputByteCounts
attemptedNativeShapes attemptedNativeDTypes primingOperations unauthenticatedArraysPublished
verifiedPlaintextDigests senderActiveBeforeCleanup receiverActiveBeforeCleanup allTrackedNativeArraysReleased
nativeAllocationsReturnedToBaseline'''


def native_bound(size):
    # Exact pinned Metal policy: round above vm_page_size, then inclusive
    # cache-reuse allowance min(n-1, 2*page-1). Host must prove 16 KiB pages.
    if size > 16_384:
        size = ((size + 16_383)//16_384)*16_384
    return size + min(size-1, 32_767)


@lru_cache(maxsize=32)
def plaintext_digest(size):
    integer(size, 'fixture plaintext size', 1, MAXIMUM)
    digest = hashlib.sha256()
    chunk = b'\x5a'*65_536
    while size:
        count = min(size, len(chunk)); digest.update(chunk[:count]); size -= count
    return digest.hexdigest()


def expected_operations(case):
    priming = case['priming']
    failing = case['failure'] != 'none'
    operations = priming + case['geometries']*case['rounds']
    count = len(operations)
    sizes, actual, shapes, types = [], [], [], []
    for index, geometry in enumerate(operations):
        failure = case['failure'] if index >= len(priming) else 'none'
        invalid = failure in ('oversize', 'shape')
        shapes.append([MAXIMUM+1] if failure == 'oversize' else [2] if failure == 'shape' else geometry['shape'])
        types.append('uint8' if failure == 'oversize' else 'uint32' if invalid else geometry['dtype'])
        sizes.append(MAXIMUM+1 if failure == 'oversize' else 8 if failure == 'shape' else geometry['bytes'])
        actual.append(4 if invalid else geometry['bytes'])
    before_send = case['failure'] in ('beforeExport', 'oversize', 'shape')
    before_io = before_send or case['failure'] == 'afterSeal'
    published = len(priming) if failing else count
    transmitted = len(priming) + (0 if before_io else 1) if failing else count
    return dict(sentRecords=len(priming)+(0 if before_send else 1) if failing else count,
        openedRecords=len(priming)+(1 if case['failure']=='afterOpen' else 0) if failing else count,
        publishedArrays=published, refusedRecords=1 if failing else 0,
        frameLengths=[geometry['bytes']+40 for geometry in operations[:transmitted]],
        plaintextByteCounts=sizes, actualInputByteCounts=actual,
        attemptedNativeShapes=shapes, attemptedNativeDTypes=types,
        verifiedPlaintextDigests=[plaintext_digest(geometry['bytes']) for geometry in operations[:published]],
        senderActiveBeforeCleanup=not (failing and before_io),
        receiverActiveBeforeCleanup=not (failing and not before_io))


def validate_result(raw, case_id, host=None):
    require(type(raw) is bytes and 0 < len(raw) <= 65_536, 'Native report byte bound')
    require(case_id in CASES, 'Unknown fixed allocation case')
    value = parse(raw); fields(value, REPORT_KEYS, 'allocation report')
    case = CASES[case_id]
    constants = dict(schema='collective_native_allocation_probe_v1',
        scope='both codec endpoints plus native staging in one process; no RDMA/group/model',
        profileQualified=False, caseID=case_id, failureMode=case['failure'],
        suite='aes256GcmHkdfSha256V1', allocatorPolicy='disable_freed_buffer_cache',
        maximumPlaintextBytes=MAXIMUM, maximumFrameBytes=MAXIMUM+40,
        maximumInFlightOperations=1, rounds=case['rounds'], primingOperations=len(case['priming']),
        unauthenticatedArraysPublished=0, allTrackedNativeArraysReleased=True,
        nativeAllocationsReturnedToBaseline=True)
    for key, wanted in constants.items(): same(value[key], wanted, key)
    for key in ('hardwareModel', 'osBuild'): text(value[key], key, 256)
    if host is not None:
        same(host['physicalMemoryBytes'], 48*1024**3, '48 GiB host')
        same(host['pageSizeBytes'], 16_384, 'native allocator page size')
        same(host['cpuBrand'], 'Apple M4 Pro', 'CPU identity')
        same(value['hardwareModel'], host['hardwareModel'], 'native hardware identity')
        same(value['osBuild'], host['osBuild'], 'native OS identity')
    expected = expected_operations(case)
    for key, wanted in expected.items(): same(value[key], wanted, key)
    geometries = []
    for geometry in case['geometries']:
        geometries.append(dict(id=geometry['id'], shape=geometry['shape'], dtype=geometry['dtype'],
            plaintextBytes=geometry['bytes'], nativeArrayBoundBytes=native_bound(geometry['bytes']),
            nativeFrameBoundBytes=native_bound(geometry['bytes']+40)))
    same(value['geometries'], geometries, 'exact catalog native geometry and allocation bounds')
    integer(value['elapsedNanoseconds'], 'native elapsed', 1, 54_999_999_999)
    for key in ('baselineNativeActiveBytes', 'observedPeakNativeActiveBytes',
                'maximumObservedNativeCacheBytes', 'finalNativeActiveBytes', 'finalNativeCacheBytes'):
        integer(value[key], key, 0, 48*1024**3)
    baseline = value['baselineNativeActiveBytes']; peak = value['observedPeakNativeActiveBytes']
    require(baseline <= peak <= baseline+256*1024**2, 'Observed native high-water exceeded fixed bound')
    same(value['finalNativeActiveBytes'], baseline, 'native active baseline return')
    same(value['maximumObservedNativeCacheBytes'], 0, 'native freed-buffer cache disabled')
    same(value['finalNativeCacheBytes'], 0, 'final native cache empty')
    for key in ('baselinePhysical', 'finalPhysical'):
        record = value[key]; fields(record, 'currentBytes lifetimeMaximumBytes', key)
        integer(record['currentBytes'], key+'.current', 1, 48*1024**3)
        integer(record['lifetimeMaximumBytes'], key+'.maximum', record['currentBytes'], 48*1024**3)
    before, after = value['baselinePhysical'], value['finalPhysical']
    require(after['lifetimeMaximumBytes'] >= before['lifetimeMaximumBytes'], 'Lost process lifetime maximum')
    increment = max(0, after['lifetimeMaximumBytes']-before['currentBytes'])
    require(increment <= 512*1024**2, 'Observed process high-water exceeded fixed bound')
    same(value['conservativeObservedPhysicalIncrementBytes'], increment, 'process increment arithmetic')
    return value
