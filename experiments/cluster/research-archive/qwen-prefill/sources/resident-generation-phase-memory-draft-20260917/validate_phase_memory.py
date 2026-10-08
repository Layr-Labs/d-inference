"""Local phase arithmetic only. Caller separately validates physical retirement.

Expected input must be prepared/pinned before the run: exact identity and 128
expected token IDs. Never derive those expected fields from the candidate.
"""
import json
from pathlib import Path

CAP = 1024 * 1024

def validate_memory(report):
    memory = report['memory']
    names = {'maximumSamples', 'minimumPeriodicIntervalNanoseconds', 'readyUptimeNanoseconds',
        'sameProcessClockAsPhases', 'includesObserverOverhead', 'streamsSynchronizedForObservation',
        'continuousOSPeakObserved', 'vmCategoriesAreDisjoint', 'preLoadSourceVerificationCovered',
        'publicationAndModelReleaseCovered', 'allocatorPeakScope', 'samples'}
    if type(memory) is not dict or set(memory) != names:
        raise ValueError('Incomplete memory observation scope')
    if type(memory['maximumSamples']) is not int or memory['maximumSamples'] != 320 or type(memory['minimumPeriodicIntervalNanoseconds']) is not int or memory['minimumPeriodicIntervalNanoseconds'] != 1_000_000_000:
        raise ValueError('Changed memory recording bounds')
    for key in ['sameProcessClockAsPhases', 'includesObserverOverhead']:
        if memory[key] is not True: raise ValueError('Missing local observation qualification')
    for key in ['streamsSynchronizedForObservation', 'continuousOSPeakObserved', 'vmCategoriesAreDisjoint',
                'preLoadSourceVerificationCovered', 'publicationAndModelReleaseCovered']:
        if memory[key] is not False: raise ValueError('Unproved memory observation scope')
    if memory['allocatorPeakScope'] != 'process_cumulative_without_reset':
        raise ValueError('Allocator peak scope changed')
    rows = memory['samples']
    if type(rows) is not list or not 5 <= len(rows) <= 320:
        raise ValueError('Memory sample capacity/mandatory anchors differ')
    integers = {'ordinal', 'startedNanoseconds', 'completedNanoseconds', 'osStartedNanoseconds', 'osCompletedNanoseconds',
        'physicalMemoryBytes', 'pageSizeBytes', 'kernelFreePages', 'freePages', 'inactivePages', 'speculativePages',
        'actualFreeBytes', 'estimatedReclaimableBytes', 'pressureLevel', 'swapUsedBytes', 'activePages', 'wiredPages',
        'purgeablePages', 'fileBackedPages', 'anonymousPages', 'compressorPages', 'activeBytes', 'cacheBytes',
        'peakBytes', 'allocatorLimitBytes', 'requiredActualFreeBytes', 'requiredAllocatorBytes'}
    previous_end = 0; periodic = None; phase = 'load'; reads = 0; total = None
    peak = 0; anchors = {}; joins = []
    physical = (24 if report['identity']['rank'] == 0 else 48) * 1024**3
    for index, row in enumerate(rows):
        if type(row) is not dict or set(row) != integers | {'point','authorizedTensorCount','selectedTensorCount'}:
            raise ValueError('Memory sample schema changed')
        if any(type(row[k]) is not int or not 0 <= row[k] < 2**64 for k in integers) or row['ordinal'] != index:
            raise ValueError('Memory scalar type/range differs')
        start, end = row['startedNanoseconds'], row['completedNanoseconds']
        if not previous_end <= start <= row['osStartedNanoseconds'] <= row['osCompletedNanoseconds'] <= end or end-start > 1_000_000_000:
            raise ValueError('Memory sampling interval reversed or stale')
        previous_end = end
        if row['physicalMemoryBytes'] != physical or not 0 < row['pageSizeBytes'] <= 65536:
            raise ValueError('Wrong host/page geometry')
        if row['kernelFreePages'] != row['freePages'] + row['speculativePages'] or row['actualFreeBytes'] != row['freePages'] * row['pageSizeBytes'] or row['estimatedReclaimableBytes'] != sum(row[k] for k in ['freePages','inactivePages','speculativePages']) * row['pageSizeBytes']:
            raise ValueError('Memory free/reclaimable arithmetic changed')
        if not 6*1024**3 <= row['requiredActualFreeBytes'] <= row['actualFreeBytes'] <= row['estimatedReclaimableBytes'] <= physical or not 0 < row['requiredAllocatorBytes'] <= row['allocatorLimitBytes']:
            raise ValueError('Memory sample did not pass unchanged admission')
        if row['pressureLevel'] not in (0,1,2) or row['swapUsedBytes'] != 0 or row['peakBytes'] < max(peak,row['activeBytes']):
            raise ValueError('Memory pressure/swap/allocator peak differs')
        peak = row['peakBytes']; point = row['point']
        if point in ('load','requestLive'):
            if periodic is not None and start-periodic < 1_000_000_000:
                raise ValueError('Periodic memory capture exceeds stated cadence')
            periodic = start
        if phase == 'load' and point == 'load': pass
        elif phase == 'load' and point == 'loadComplete': phase = point
        elif phase == 'loadComplete' and point == 'loadedRequestGuard': phase = point
        elif phase == 'loadedRequestGuard' and point == 'requestBegin': phase = point
        elif phase in ('requestBegin','requestLive') and point in ('requestLive','requestRetired'): phase = point
        else: raise ValueError('Memory load/readiness/request/retirement order differs')
        if index == 0 and point != 'load': raise ValueError('No initial materializer snapshot')
        if point in ('load','loadComplete'):
            a,b = row['authorizedTensorCount'],row['selectedTensorCount']
            if type(a) is not int or type(b) is not int or not 0 <= reads <= a <= b or b != (463 if report['identity']['rank'] == 0 else 1384) or (total is not None and b != total) or (index == 0 and a != 0) or (point == 'loadComplete' and a != b):
                raise ValueError('Selected-load progress differs')
            reads,total = a,b
        elif row['authorizedTensorCount'] is not None or row['selectedTensorCount'] is not None:
            raise ValueError('Request sample invents tensor-read progress')
        if point not in ('load','requestLive'): anchors[point] = row
        preceding = [e['ordinal'] for e in report['events'] if e['localUptimeNanoseconds'] <= start]
        following = [e['ordinal'] for e in report['events'] if e['localUptimeNanoseconds'] >= end]
        joins.append(dict(sampleOrdinal=index, precedingPhaseOrdinal=preceding[-1] if preceding else None,
                          followingPhaseOrdinal=following[0] if following else None))
    ready = memory['readyUptimeNanoseconds']
    if phase != 'requestRetired' or type(ready) is not int or not anchors['loadedRequestGuard']['completedNanoseconds'] <= ready <= anchors['requestBegin']['startedNanoseconds']:
        raise ValueError('Missing native readiness/request retirement')
    if anchors['requestBegin']['completedNanoseconds'] > report['firstLocalUptimeNanoseconds'] or anchors['requestRetired']['startedNanoseconds'] < report['lastLocalUptimeNanoseconds'] or rows[-1]['completedNanoseconds'] - rows[0]['startedNanoseconds'] > 300_000_000_000:
        raise ValueError('Memory interval does not bracket the same native request')
    return dict(sampleCount=len(rows), minimumSampledActualFreeBytes=min(x['actualFreeBytes'] for x in rows),
        maximumSampledActiveBytes=max(x['activeBytes'] for x in rows), maximumSampledCacheBytes=max(x['cacheBytes'] for x in rows),
        cumulativeAllocatorPeakBytes=max(x['peakBytes'] for x in rows), sameProcessPhaseJoins=joins,
        anchors={k:v['ordinal'] for k,v in anchors.items()}, continuousOSPeakProved=False,
        workspaceOwnershipInferred=False, placementPermissionGranted=False)

def expected_events(rank, policy):
    out = []
    def add(name, frame=None, local=None, agreed=None):
        descriptor = None if frame is None else dict(sequence=frame, tokenOffset=frame*256,
            tokenCount=256, finalPromptChunk=frame == 31)
        out.append(dict(phase=name, frame=descriptor, localCommittedTokens=local,
                        agreedCommittedTokens=agreed))
    for name in ['requestBegin', 'readinessBegin', 'readinessEnd', 'stateBegin']:
        add(name)
    add('stateEnd', local=0)
    def prepare(k):
        add('prepareBegin', k, local=k*256); add('prepareEnd', k, local=(k+1)*256)
    for k in range(32):
        add('frameBegin', k, agreed=k*256)
        if rank == 0:
            if policy == 'serial' or k == 0:
                prepare(k)
            for name in ['headerSendBegin', 'headerSendEnd', 'readyAckWaitBegin',
                         'readyAckWaitEnd', 'payloadSendBegin', 'payloadSendEnd']:
                add(name, k)
            if policy == 'oneChunkLookahead':
                add('originalWrapperReleased', k, local=(k+1)*256)
                if k < 31:
                    prepare(k+1)
            add('consumedAckWaitBegin', k); add('consumedAckWaitEnd', k)
        else:
            for name in ['headerReceiveBegin', 'headerReceiveEnd', 'readyAckSendBegin',
                         'readyAckSendEnd', 'payloadReceiveBegin', 'payloadReceiveEnd', 'payloadValidated']:
                add(name, k)
            add('consumeBegin', k, local=k*256)
            add('consumeEnd', k, local=(k+1)*256, agreed=(k+1)*256)
            add('consumedAckSendBegin', k); add('consumedAckSendEnd', k)
    names = ['tokenReceiveBegin', 'tokenReceiveEnd', 'tokenAckBegin', 'tokenAckEnd'] if rank == 0 else [
        'selectionBegin', 'selectionEnd', 'tokenSendBegin', 'tokenSendEnd']
    for name in names:
        add(name, 31)
    add('firstTokenAgreed', 31, agreed=8192)
    add('requestRetired', local=8319, agreed=8319)
    return out

def validate(report, expected):
    if type(expected) is not dict or set(expected) != {'identity', 'expectedTokenIDs'} or type(expected['expectedTokenIDs']) is not list or len(expected['expectedTokenIDs']) != 128 or any(type(v) is not int or not 0 <= v < 248320 for v in expected['expectedTokenIDs']):
        raise ValueError('Incomplete prospective identity/target expectation')
    if report.get('schema') != 'qwen_resident_generation_phase_memory_report_v1':
        raise ValueError('Wrong phase schema')
    fields = {'schema', 'memory', 'identity', 'clockSource', 'protocolBoundary', 'budget',
        'liveResourceChecksBeforeEncoding', 'execution', 'firstLocalUptimeNanoseconds',
        'lastLocalUptimeNanoseconds', 'events', 'diagnosticOnly', 'includesRecorderOverhead',
        'mtpEnabled', 'modelRemainsResident', 'crossProcessClockAlignmentAsserted',
        'gpuKernelTimeAsserted', 'transportWaitIsWireCost', 'ownerLeaseRetirementIndependentlyVerified',
        'independentNumericalComparisonPerformed', 'wholeProcessPeakBoundProved'}
    if set(report) != fields:
        raise ValueError('Unexpected report fields')
    identity = report['identity']
    if identity != expected['identity']:
        raise ValueError('Candidate identity differs from prospective expectation')
    hashes = ['requestFingerprint', 'agreementFingerprint', 'profileFingerprint',
        'sourceConfigurationSHA256', 'artifactAggregateSHA256', 'storageCommitmentSHA256',
        'planFingerprint', 'stageFingerprint', 'buildSHA256', 'numericalPolicySHA256']
    if set(identity) != set(hashes + ['requestID', 'membershipEpoch', 'rank', 'promptCount', 'chunkSize', 'outputCount', 'prefillPolicy']):
        raise ValueError('Incomplete prospective identity')
    import uuid
    for key in ['requestID', 'membershipEpoch']:
        if str(uuid.UUID(identity[key])) != identity[key]:
            raise ValueError('Noncanonical UUID')
    for key in hashes:
        value = identity[key]
        if type(value) is not str or len(value) != 64 or any(c not in '0123456789abcdef' for c in value):
            raise ValueError('Noncanonical identity digest')
    rank, policy = identity['rank'], identity['prefillPolicy']
    if type(rank) is not int or rank not in [0, 1] or policy not in ['serial', 'oneChunkLookahead']:
        raise ValueError('Closed rank/policy required')
    if any(type(identity[k]) is not int for k in ['promptCount', 'chunkSize', 'outputCount']) or [identity['promptCount'], identity['chunkSize'], identity['outputCount']] != [8192, 256, 128]:
        raise ValueError('Closed workload required')
    if report['clockSource'] != 'dispatch_uptime_nanoseconds' or report['protocolBoundary'] != 'resident_generation_send_completed_credit_v1':
        raise ValueError('Wrong local clock/protocol')
    for key in ['diagnosticOnly', 'includesRecorderOverhead', 'modelRemainsResident']:
        if report[key] is not True:
            raise ValueError('Missing diagnostic qualification')
    for key in ['mtpEnabled', 'crossProcessClockAlignmentAsserted', 'gpuKernelTimeAsserted',
                'transportWaitIsWireCost', 'ownerLeaseRetirementIndependentlyVerified',
                'independentNumericalComparisonPerformed', 'wholeProcessPeakBoundProved']:
        if report[key] is not False:
            raise ValueError('Unproved claim')
    execution = report['execution']
    if set(execution) != {'completedFrames', 'committedTokens', 'tokenChainSHA256', 'finishReason', 'bothRequestStatesRetired', 'selectedTokenIDs'}:
        raise ValueError('Unexpected execution fields')
    if any(type(v) is not int or not 0 <= v < 248320 for v in execution['selectedTokenIDs']) or execution['selectedTokenIDs'] != expected['expectedTokenIDs'] or len(execution['selectedTokenIDs']) != 128:
        raise ValueError('Full target token sequence differs')
    chain = execution['tokenChainSHA256']
    if type(chain) is not str or len(chain) != 64 or any(c not in '0123456789abcdef' for c in chain):
        raise ValueError('Invalid token-chain digest')
    if type(execution['completedFrames']) is not int or type(execution['committedTokens']) is not int or execution['completedFrames'] != 159 or execution['committedTokens'] != 8319 or execution['finishReason'] != 'length' or execution['bothRequestStatesRetired'] is not True:
        raise ValueError('Incomplete native request')
    budget = report['budget']
    keys = ['eventLogicalBytes', 'eventAllocationBytes', 'encodedResultAllocationBytes',
            'encodingScratchAllowanceBytes', 'metadataAllowanceBytes', 'requiredHostReservationBytes', 'totalReservedBytes']
    if set(budget) != set(keys) | {'maximumEvents','memoryLogicalBytes','memoryAllocationBytes'} or any(type(budget[k]) is not int or budget[k] <= 0 for k in keys) or type(budget['maximumEvents']) is not int or budget['maximumEvents'] != 544:
        raise ValueError('Invalid named host budget')
    components = keys[1:5] + ['memoryAllocationBytes']
    if any(type(budget[k]) is not int or budget[k] <= 0 for k in ['memoryLogicalBytes','memoryAllocationBytes']) or budget['memoryAllocationBytes'] < budget['memoryLogicalBytes']:
        raise ValueError('Memory host buffer bound differs')
    if budget['requiredHostReservationBytes'] != sum(budget[k] for k in components) or budget['requiredHostReservationBytes'] > 8*1024*1024 or budget['eventAllocationBytes'] < budget['eventLogicalBytes'] or budget['encodedResultAllocationBytes'] < CAP or budget['encodingScratchAllowanceBytes'] < 2*CAP or budget['metadataAllowanceBytes'] < 16384 or budget['totalReservedBytes'] <= budget['requiredHostReservationBytes']:
        raise ValueError('Host budget algebra differs')
    if type(report['liveResourceChecksBeforeEncoding']) is not int or report['liveResourceChecksBeforeEncoding'] <= 0:
        raise ValueError('No live resource checks')
    events, wanted = report['events'], expected_events(rank, policy)
    if len(events) != len(wanted):
        raise ValueError('Missing or extra native phase events')
    def same(actual, wanted):
        if type(actual) is not type(wanted):
            return False
        if isinstance(wanted, dict):
            return set(actual) == set(wanted) and all(same(actual[k], v) for k, v in wanted.items())
        return actual == wanted
    previous, pairs, intervals = 0, {}, []
    for ordinal, (event, want) in enumerate(zip(events, wanted)):
        if set(event) != set(want) | {'ordinal', 'localUptimeNanoseconds'} or not same(event['ordinal'], ordinal) or any(not same(event[k], v) for k, v in want.items()):
            raise ValueError('Native action order/frontier differs')
        stamp = event['localUptimeNanoseconds']
        if type(stamp) is not int or not previous <= stamp < 2**64:
            raise ValueError('Local monotonic timestamp reversed')
        previous = stamp
        frame = event['frame']['sequence'] if event['frame'] else None
        phase = event['phase']
        if phase.endswith('Begin'):
            pairs[(phase[:-5], frame)] = stamp
        elif phase.endswith('End'):
            start = pairs.pop((phase[:-3], frame))
            intervals.append(dict(phase=phase[:-3], frame=frame, localDurationNanoseconds=stamp-start))
    if type(report['firstLocalUptimeNanoseconds']) is not int or type(report['lastLocalUptimeNanoseconds']) is not int or report['firstLocalUptimeNanoseconds'] != events[0]['localUptimeNanoseconds'] or report['lastLocalUptimeNanoseconds'] != events[-1]['localUptimeNanoseconds']:
        raise ValueError('Trace endpoint mismatch')
    memory = validate_memory(report)
    return dict(rank=rank, policy=policy, events=len(events), localIntervals=intervals, memory=memory,
        physicalCleanupValidated=False, externalReservationEvidenceValidated=False,
        gpuTimeOrWireCostOrCrossHostOffsetInferred=False)

def read(path, limit):
    import os, stat
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            raise ValueError('Expected regular input file')
        with os.fdopen(descriptor, 'rb', closefd=False) as stream:
            data = stream.read(limit + 1)
    finally:
        os.close(descriptor)
    if not 0 < len(data) <= limit:
        raise ValueError('Input exceeds byte bound')
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError('Duplicate key')
            result[key] = value
        return result
    return json.loads(data, object_pairs_hook=unique, parse_constant=lambda _: (_ for _ in ()).throw(ValueError('Nonfinite number')))

if __name__ == '__main__':
    import sys
    candidate, prospective = sys.argv[1:]
    print(json.dumps(validate(read(candidate, CAP), read(prospective, 16384)), sort_keys=True))
