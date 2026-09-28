"""Pure local phase replay after public registered rank-report validation.

No file IO, model admission, executable/device inference or numerical audit.
Call long_rank_contract.validate for both ready/final pairs before this layer.
"""
import math
from runtime.stage_checks.common import exact, integer, require, sha
from runtime.stage_checks.long_profile import PROFILE, PROFILE_SHA256
from .qwen_phase_actions import expected_actions, timing_flags

U64 = 2**64 - 1
TRACE_FIELDS = set(('kind schemaVersion identity clockSource maximumEvents events '
    'firstLocalUptimeNanoseconds lastLocalUptimeNanoseconds traceSpanNanoseconds '
    'diagnosticOnly includesRecorderOverhead crossProcessClockAlignmentAsserted gpuOverlapAsserted '
    'modelReleaseAsserted recorderIndependentlyVerifiesRequestRetirement').split())
EXECUTION_FIELDS = set(('kind schemaVersion correctnessOnly throughputMeasurementValid interprocessTransportUsed '
    'physicalTransferQualified independentNumericalComparisonPerformed profile profileFingerprint agreementFingerprint '
    'identity readiness frames actions selectedTokenID exactTokenPacketJSON tokenPacketFingerprint tokenPacketWireBytesSHA256 '
    'finalDigest completedFrames committedTokens preparedAheadFrames releasedOriginalBoundaryHandles postStopReleaseCompleted '
    'allRequestStateRetired originalWrapperReleaseIsNotProofOfNoStorageAliases').split())


def _fields(value, wanted, label):
    require(type(value) is dict and set(value) == wanted, label + ': fields differ')


def _values(value, **wanted):
    for key, expected in wanted.items():
        require(key in value, 'Missing phase metadata: ' + key)
        exact(value[key], expected, 'Phase metadata differs: ' + key)


def _primary_clock(value):
    numbers = {'startUptimeNanoseconds', 'stopUptimeNanoseconds', 'elapsedNanoseconds',
               'promptTokensPerFirstTokenSecond', 'postStopThroughRequestCloseNanoseconds'}
    _fields(value, numbers | set(timing_flags()), 'rank0 primary clock')
    _values(value, **timing_flags())
    start = integer(value['startUptimeNanoseconds'], 0, U64)
    stop = integer(value['stopUptimeNanoseconds'], 0, U64)
    elapsed = integer(value['elapsedNanoseconds'], 1, U64)
    post = integer(value['postStopThroughRequestCloseNanoseconds'], 0, U64)
    require(start < stop and stop - start == elapsed and stop + post <= U64,
            'Primary UInt64 clock arithmetic differs')
    rate = value['promptTokensPerFirstTokenSecond']
    require(type(rate) in (int, float) and math.isfinite(rate) and rate == 8192e9 / float(elapsed),
            'Primary diagnostic rate differs')
    return dict(start=start, stop=stop, closed=stop + post)


def validate_rank_phase(report, trace, rank):
    """Validate local actions/clocks for one already outer-validated final report."""
    integer(rank, 0, 1)
    require(type(report) is dict and type(report.get('agreement')) is dict
            and type(report.get('request')) is dict, 'Validated rank report required')
    _values(report, kind='qwen_long_prefill_rank_report', rank=rank)
    agreement, request, execution = report['agreement'], report['request'], report['execution']
    _values(agreement, profile=PROFILE, profileFingerprint=PROFILE_SHA256,
            promptCount=8192, chunkSize=512, outputCount=1, batchSize=1, frameCount=16)
    policy = agreement['schedulingPolicy']
    actions = expected_actions(rank, policy)
    role = 'rank' + str(rank)
    recorded = sha(request['fingerprint'])
    exact(recorded, agreement['recordedRequestFingerprint'], 'Recorded history differs from agreement')
    _fields(execution, EXECUTION_FIELDS | ({'timing'} if rank == 0 else {'localSelection'}), 'rank execution')
    _values(execution, kind='qwen_long_prefill_rank_request', schemaVersion=1, correctnessOnly=True,
            throughputMeasurementValid=False, interprocessTransportUsed=True, physicalTransferQualified=False,
            independentNumericalComparisonPerformed=False, profile=PROFILE, profileFingerprint=PROFILE_SHA256,
            agreementFingerprint=report['agreementFingerprint'], completedFrames=16, committedTokens=8192,
            preparedAheadFrames=15 if rank == 0 and policy == 'prompt_lookahead_one_v1' else 0,
            releasedOriginalBoundaryHandles=16, postStopReleaseCompleted=True, allRequestStateRetired=True,
            originalWrapperReleaseIsNotProofOfNoStorageAliases=True)
    exact(execution['actions'], actions, 'Actual scalar action sequence differs')
    frames = execution['frames']
    require(type(frames) is list and len(frames) == 16, 'Sixteen native frame records required')
    for i, frame in enumerate(frames):
        _fields(frame, {'commit', 'exactEnvelopeJSON', 'envelopeFingerprint', 'envelopeWireBytesSHA256'}, 'frame')
        require(type(frame['commit']) is dict, 'Frame commit metadata required')
        exact(frame['commit'].get('frame'), dict(phase='prefill', sequence=i, tokenOffset=i*512,
              tokenCount=512, finalPromptChunk=i == 15), 'Committed frame geometry differs')
        exact(frame['commit'].get('committedTokens'), (i+1)*512, 'Committed frame frontier differs')

    _fields(trace, TRACE_FIELDS, 'phase trace')
    _values(trace, kind='qwen_prefill_local_phase_trace', schemaVersion=1,
            clockSource='DispatchTime.uptimeNanoseconds', maximumEvents=512,
            diagnosticOnly=True, includesRecorderOverhead=True, crossProcessClockAlignmentAsserted=False,
            gpuOverlapAsserted=False, modelReleaseAsserted=False, recorderIndependentlyVerifiesRequestRetirement=False)
    exact(trace['identity'], dict(requestFingerprint=recorded, profile=PROFILE, role=role), 'Trace identity differs')
    events = trace['events']
    require(type(events) is list and len(events) == len(actions) <= 512, 'Bounded exact event count required')
    previous = 0
    for event, action in zip(events, actions):
        wanted = dict(ordinal=action['ordinal'], phase=action['action'], committedTokens=action['nativeCommittedTokens'])
        if 'frameSequence' in action:
            wanted['frameSequence'] = action['frameSequence']
        _fields(event, set(wanted) | {'localUptimeNanoseconds'}, 'phase event')
        exact({key: event[key] for key in wanted}, wanted, 'Phase/action observation differs')
        now = integer(event['localUptimeNanoseconds'], 0, U64)
        require(now >= previous, 'Local uptime reversed')
        previous = now
    first = integer(trace['firstLocalUptimeNanoseconds'], 0, U64)
    last = integer(trace['lastLocalUptimeNanoseconds'], 0, U64)
    span = integer(trace['traceSpanNanoseconds'], 0, U64)
    require(first == events[0]['localUptimeNanoseconds'] and last == events[-1]['localUptimeNanoseconds']
            and first <= last and last-first == span, 'Trace endpoint/span arithmetic differs')
    lookup = {(e['phase'], e.get('frameSequence')): e for e in events}
    require(len(lookup) == len(events), 'Duplicate phase/frame observation')
    clock = _primary_clock(execution['timing']) if rank == 0 else None
    if rank == 0:
        time = lambda phase: lookup[phase, None]['localUptimeNanoseconds']
        require(time('readiness.completed') <= clock['start'] <= time('control.beginStartSend')
                and time('control.tokenValidated') <= clock['stop'] <= time('firstTokenStopRecorded')
                and time('requestClosed') <= clock['closed'], 'Primary clock/source marker enclosure differs')

    def service(i, start, end, selection=False, adjacent=False):
        a, b = lookup[start, i], lookup[end, i]
        require(a['ordinal'] < b['ordinal'] and (not adjacent or b['ordinal'] == a['ordinal'] + 1),
                'Local service marker order differs')
        return dict(frameSequence=i, tokenOffset=i*512, tokenCount=512, committedTokens=(i+1)*512,
                    elapsedNanoseconds=b['localUptimeNanoseconds']-a['localUptimeNanoseconds'],
                    startOrdinal=a['ordinal'], endOrdinal=b['ordinal'], startPhase=start, endPhase=end,
                    includesFinalSelection=selection)

    start, end = (('prepare.begin', 'prepare.committed') if rank == 0 else
                  ('receive.beginConsumption', 'receive.consumptionAndSelectionValidated'))
    services = [service(i, start, end, selection=rank == 1 and i == 15) for i in range(16)]
    total = sum(s['elapsedNanoseconds'] for s in services)
    require(total <= span and all(a['endOrdinal'] <= b['startOrdinal'] for a, b in zip(services, services[1:])),
            'Primary local services overlap or exceed trace')
    pre_header = ([service(i, 'prepare.committed', 'send.beginHeader', adjacent=True) for i in range(16)]
                  if rank == 0 and policy == 'serial_v1' else None)
    if pre_header is not None:
        require(total + sum(s['elapsedNanoseconds'] for s in pre_header) <= span,
                'Disjoint local service total exceeds trace')
    return dict(status='passed', rank=rank, role=role, profile=PROFILE, profileFingerprint=PROFILE_SHA256,
                recordedRequestFingerprint=recorded, requestFingerprint=agreement['requestFingerprint'],
                agreementFingerprint=report['agreementFingerprint'], epoch=report['epoch'], schedulingPolicy=policy,
                promptFileSHA256=report['promptFileSHA256'], promptTokenIDsSHA256=agreement['promptTokenIDsSHA256'],
                clockSource=trace['clockSource'], eventCount=len(events), maximumEvents=512,
                firstLocalUptimeNanoseconds=first, lastLocalUptimeNanoseconds=last, traceSpanNanoseconds=span,
                localPrimaryClock=clock, frameCount=16, committedTokens=8192, services=services,
                serviceKind='stage0_prepare_cpu_observed' if rank == 0 else 'stage1_consume_and_final_selection_cpu_observed',
                totalServiceNanoseconds=total, serialPreHeaderServices=pre_header,
                phaseReplayPerformed=True, numericalValidationPerformed=False, modelAdmissionPerformed=False,
                nativeExecutionIndependentlyVerified=False, physicalDeviceIdentityDerived=False,
                crossProcessClockAlignmentAsserted=False, gpuKernelTimeAsserted=False)


def validate_phase_pair(reports, traces):
    """Ordered rank0/rank1 reports and traces; compare identities, never clocks."""
    require(type(reports) is list and len(reports) == 2 and type(traces) is list and len(traces) == 2,
            'Two ordered rank reports and phase traces required')
    ranks = [validate_rank_phase(r, t, i) for i, (r, t) in enumerate(zip(reports, traces))]
    for key in ['epoch', 'schedulingPolicy', 'recordedRequestFingerprint', 'requestFingerprint',
                'agreementFingerprint', 'promptFileSHA256', 'promptTokenIDsSHA256', 'profile', 'profileFingerprint']:
        exact(ranks[0][key], ranks[1][key], 'Cross-rank identity differs: ' + key)
    return dict(status='passed', ranks=ranks, phaseReplayPerformed=True,
                crossProcessClockAlignmentAsserted=False, crossRankIntervalTotalsComputed=False,
                numericalValidationPerformed=False, nativeExecutionIndependentlyVerified=False,
                physicalDeviceIdentityDerived=False, gpuKernelTimeAsserted=False)
