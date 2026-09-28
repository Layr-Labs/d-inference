"""Pure checks of the frozen controller's completed cancellation/recovery DTOs."""
from decimal import Decimal
import hashlib
import re
import uuid


def require(condition, message):
    if not condition:
        raise ValueError(message)


def integer(value, minimum=0, maximum=(1 << 63) - 1):
    require(type(value) is int and minimum <= value <= maximum, 'Invalid exact integer')
    return value


def canonical_uuid(value):
    require(type(value) is str and str(uuid.UUID(value)) == value, 'Noncanonical UUID')
    return value


def token_hash(values):
    require(type(values) is list and all(type(v) is int and v >= 0 for v in values), 'Invalid token vector')
    return hashlib.sha256(','.join(map(str, values)).encode()).hexdigest()


def all_true(value, count):
    return type(value) is list and len(value) == count and all(v is True for v in value)


def observations(config, records, config_sha):
    require(type(records) is list and len(records) == 4, 'Expected start, cancellation, recovery and final records')
    started, first, second, final = records
    require([v.get('schema') for v in records] == ['owner_cancellation_recovery_started_v1',
        'owner_cancellation_request_v1', 'owner_cancellation_request_v1', 'owner_cancellation_recovery_result_v1'], 'Wrong record order')
    require(all(v['configurationSHA256'] == config_sha for v in records), 'Configuration pin differs')
    require(started['cancellationCase'] == final['cancellationCase'] == config['cancellationCase'], 'Case differs')
    require(started['cancellationEpoch'] == config['cancellationEpoch'] and started['recoveryEpoch'] == config['recoveryEpoch'], 'Epochs differ')
    require(started['nativeKernelPhaseObserved'] is False, 'Unsupported kernel phase claim')
    require(started['promptTokenIDsSHA256'] == token_hash(config['promptTokenIDs']) and
            started['expectedTokenIDsSHA256'] == token_hash(config['expectedTokenIDs']), 'Token input pins differ')
    require(final['completed'] is True and 'failure' not in final, 'Incomplete final controller result')
    require(final['clock'] == 'DispatchTime.uptimeNanoseconds.same_controller_process', 'Wrong clock scope')
    require(final['freshPairAndMembershipRequired'] is True, 'Fresh membership requirement absent')
    for key in ['oldEpochReuseQualified', 'independentRemoteJournalObservation', 'nativeKernelPhaseObserved',
                'fullNumericalComparisonPerformed', 'externalTTFTMeasured', 'performanceQualification', 'providerCapacityUpdated']:
        require(final[key] is False, 'Unsupported controller qualification: ' + key)
    require(all_true(final['nativeCleanupObserved'], 4) and all_true(final['ownerDeviceLeaseReleasedObserved'], 4),
            'Missing one of four native/owner cleanup observations')
    pairs = [first['observation'], second['observation']]
    require(final['requests'] == pairs, 'Final records differ from original request publications')
    keys = ['startCalled', 'retirementObserved', 'resourcesReleased', 'cleanupCompleted', 'ownerLeaseDrainCompleted']
    for index, value in enumerate(pairs):
        require(value['phase'] == ('recovery' if index else 'cancellation'), 'Phase/order differs')
        require(value['membershipEpoch'] == config['recoveryEpoch' if index else 'cancellationEpoch'], 'Observed epoch differs')
        canonical_uuid(value['membershipEpoch']); canonical_uuid(value['requestID'])
        require(value['completed'] is True and 'failure' not in value, 'Failed request was included')
        require(all_true(value['nativeCleanupObserved'], 2) and all_true(value['ownerLeaseReleaseObserved'], 2), 'Missing per-incarnation cleanup')
        values = [integer(value[k], 1) for k in keys]
        require(values == sorted(values), 'Retirement/release/cleanup ordering differs')
        integer(value['reservedBytes'], 1)
        require(integer(value['bytesAfterRelease']) == 0, 'Request charge remains after release')
        token_hash(value['tokenIDs'])
    a, b = pairs
    require(a['membershipEpoch'] != b['membershipEpoch'] and a['requestID'] != b['requestID'], 'Epoch or request was reused')
    require(b['startCalled'] >= a['ownerLeaseDrainCompleted'], 'Recovery starts before prior cleanup/lease ACK')
    count = {'startedBeforeFirstToken': 0, 'afterFirstDecode': 2}[config['cancellationCase']]
    require(integer(a['tokenCountAtCancel']) == count and a['tokenIDs'] == config['expectedTokenIDs'][:count], 'Cancellation phase/prefix differs')
    require(a['phaseMatched'] is True and a['retiredBeforeCancel'] is False and a['pairUnavailableAfterCancel'] is True,
            'Cancel did not interrupt an active request and invalidate Pair')
    require('finishReason' not in a, 'Cancellation published a clean finish')
    if 'failureCallback' in a:
        require(type(a['failureCallback']) is str and 0 < len(a['failureCallback']) <= 2048, 'Invalid failure callback')
    require(integer(a['bytesAfterEarlyRelease'], 1) == a['reservedBytes'], 'Early release dropped the reservation')
    cancel = integer(a['cancelCalled'], 1)
    require(a['startCalled'] <= cancel <= a['retirementObserved'], 'Cancel was late or precedes start')
    require(cancel - a['startCalled'] < config['requestSeconds'] * 10**9, 'Cancellation outside request deadline')
    if count == 0:
        require(cancel - a['startCalled'] >= config['beforeFirstDelayMilliseconds'] * 10**6, 'Declared delay was not observed')
    require(b['tokenIDs'] == config['expectedTokenIDs'] and len(b['tokenIDs']) == 128 and b['finishReason'] == 'length', 'Recovery sequence/finish differs')
    require(b['phaseMatched'] is False and b['pairUnavailableAfterCancel'] is False, 'Recovery reported cancellation')
    for key in ['cancelCalled', 'tokenCountAtCancel', 'retiredBeforeCancel', 'bytesAfterEarlyRelease', 'failureCallback']:
        require(key not in b, 'Recovery unexpectedly cancelled/failed: ' + key)
    elapsed = integer(final['elapsedControllerNanoseconds'], 1, (config['lifetimeSeconds'] + 5) * 10**9)
    require(b['ownerLeaseDrainCompleted'] - a['startCalled'] <= elapsed, 'Request timeline exceeds controller elapsed interval')
    return {'cancellationCase': config['cancellationCase'], 'tokenCountAtCancel': count,
        'cancellationRequestID': a['requestID'], 'recoveryRequestID': b['requestID'],
        'cancellationEpoch': a['membershipEpoch'], 'recoveryEpoch': b['membershipEpoch'],
        'cancelAfterStartNanoseconds': cancel - a['startCalled'], 'reservedBytes': [a['reservedBytes'], b['reservedBytes']],
        'recoverySelectedTokenIDsSHA256': token_hash(b['tokenIDs']), 'bothGenerationsNativeCleanupAndLeaseACKReported': True}


def resources(rows):
    require(type(rows) is list and 0 < len(rows) <= 10000, 'Missing or excessive resource samples')
    previous = 0
    for i, value in enumerate(rows):
        require(value['schema'] == 'native_owner_resource_observation_v1' and integer(value['ordinal']) == i, 'Wrong resource ordinal/schema')
        start, end = integer(value['startedMonotonicNS']), integer(value['completedMonotonicNS'])
        require(previous <= start <= end, 'Local resource clock order differs'); previous = end
        page = int(re.search(r'page size of (\d+) bytes', value['rawVMStat'])[1])
        free = int(re.search(r'Pages free:\s+(\d+)\.', value['rawVMStat'])[1])
        require(integer(value['actualFreeBytes']) == page * free >= 6 * 1024**3, 'Actual-free floor/arithmetic differs')
        require(value['admissible'] is True and value['acPower'] is True and "Now drawing from 'AC Power'" in value['rawPower'], 'Resource/power admission failed')
        pressure = integer(value['pressureLevel'], 0, 2)
        require(value['rawMemory'].splitlines()[0] == str(pressure), 'Pressure differs from raw observation')
        require(type(value['reportedSwapBytes']) is str and Decimal(value['reportedSwapBytes']) == 0, 'Nonzero reported swap')
        require(Decimal(re.search(r'used\s*=\s*([0-9.]+)[KMG]', value['rawMemory'])[1]) == 0, 'Raw swap is nonzero')
    return {'sampleCount': len(rows), 'minimumActualFreeBytes': min(r['actualFreeBytes'] for r in rows),
        'allAdmissibleACZeroReportedSwap': True, 'maximumPressureLevel': max(r['pressureLevel'] for r in rows)}
