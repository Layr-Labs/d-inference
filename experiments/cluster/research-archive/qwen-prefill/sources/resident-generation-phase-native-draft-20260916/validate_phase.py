"""Local phase arithmetic only. Caller separately validates physical retirement.

Expected input must be prepared/pinned before the run: exact identity and 128
expected token IDs. Never derive those expected fields from the candidate.
"""
import json
from pathlib import Path

CAP = 256 * 1024

def expected_events(rank, policy):
    out = []
    def add(name, frame=None, local=None, agreed=None):
        descriptor = None if frame is None else dict(sequence=frame, tokenOffset=frame*512,
            tokenCount=512, finalPromptChunk=frame == 15)
        out.append(dict(phase=name, frame=descriptor, localCommittedTokens=local,
                        agreedCommittedTokens=agreed))
    for name in ['requestBegin', 'readinessBegin', 'readinessEnd', 'stateBegin']:
        add(name)
    add('stateEnd', local=0)
    def prepare(k):
        add('prepareBegin', k, local=k*512); add('prepareEnd', k, local=(k+1)*512)
    for k in range(16):
        add('frameBegin', k, agreed=k*512)
        if rank == 0:
            if policy == 'serial' or k == 0:
                prepare(k)
            for name in ['headerSendBegin', 'headerSendEnd', 'readyAckWaitBegin',
                         'readyAckWaitEnd', 'payloadSendBegin', 'payloadSendEnd']:
                add(name, k)
            if policy == 'oneChunkLookahead':
                add('originalWrapperReleased', k, local=(k+1)*512)
                if k < 15:
                    prepare(k+1)
            add('consumedAckWaitBegin', k); add('consumedAckWaitEnd', k)
        else:
            for name in ['headerReceiveBegin', 'headerReceiveEnd', 'readyAckSendBegin',
                         'readyAckSendEnd', 'payloadReceiveBegin', 'payloadReceiveEnd', 'payloadValidated']:
                add(name, k)
            add('consumeBegin', k, local=k*512)
            add('consumeEnd', k, local=(k+1)*512, agreed=(k+1)*512)
            add('consumedAckSendBegin', k); add('consumedAckSendEnd', k)
    names = ['tokenReceiveBegin', 'tokenReceiveEnd', 'tokenAckBegin', 'tokenAckEnd'] if rank == 0 else [
        'selectionBegin', 'selectionEnd', 'tokenSendBegin', 'tokenSendEnd']
    for name in names:
        add(name, 15)
    add('firstTokenAgreed', 15, agreed=8192)
    add('requestRetired', local=8319, agreed=8319)
    return out

def validate(report, expected):
    if type(expected) is not dict or set(expected) != {'identity', 'expectedTokenIDs'} or type(expected['expectedTokenIDs']) is not list or len(expected['expectedTokenIDs']) != 128 or any(type(v) is not int or not 0 <= v < 248320 for v in expected['expectedTokenIDs']):
        raise ValueError('Incomplete prospective identity/target expectation')
    if report.get('schema') != 'qwen_resident_generation_phase_report_v1':
        raise ValueError('Wrong phase schema')
    fields = {'schema', 'identity', 'clockSource', 'protocolBoundary', 'budget',
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
    if any(type(identity[k]) is not int for k in ['promptCount', 'chunkSize', 'outputCount']) or [identity['promptCount'], identity['chunkSize'], identity['outputCount']] != [8192, 512, 128]:
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
    if type(execution['completedFrames']) is not int or type(execution['committedTokens']) is not int or execution['completedFrames'] != 143 or execution['committedTokens'] != 8319 or execution['finishReason'] != 'length' or execution['bothRequestStatesRetired'] is not True:
        raise ValueError('Incomplete native request')
    budget = report['budget']
    keys = ['eventLogicalBytes', 'eventAllocationBytes', 'encodedResultAllocationBytes',
            'encodingScratchAllowanceBytes', 'metadataAllowanceBytes', 'requiredHostReservationBytes', 'totalReservedBytes']
    if set(budget) != set(keys) | {'maximumEvents'} or any(type(budget[k]) is not int or budget[k] <= 0 for k in keys) or type(budget['maximumEvents']) is not int or budget['maximumEvents'] != 288:
        raise ValueError('Invalid named host budget')
    components = keys[1:5]
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
    return dict(rank=rank, policy=policy, events=len(events), localIntervals=intervals,
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
