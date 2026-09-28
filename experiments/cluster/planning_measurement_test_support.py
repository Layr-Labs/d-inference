"""Test support only: fabricated clocks/actions, never native measurement evidence."""
from copy import deepcopy
from planning.measurements.qwen_phase_actions import expected_actions, timing_flags


def fabricated_phase(report, *, clock_origin=1000, tick=10):
    """Enrich a synthetic public rank report; return its copy and a fake trace.

    The caller supplies its existing public ready/final fixture. Opaque frame,
    state, token and ownership fields below are deliberately not a numeric proof.
    Production-clock labels are fabricated solely to exercise accepted parsing.
    """
    report = deepcopy(report)
    rank, agreement = report['rank'], report['agreement']
    actions = expected_actions(rank, agreement['schedulingPolicy'])
    events = []
    for action in actions:
        event = dict(ordinal=action['ordinal'], phase=action['action'],
                     committedTokens=action['nativeCommittedTokens'],
                     localUptimeNanoseconds=clock_origin + (action['ordinal'] + 1)*tick)
        if 'frameSequence' in action:
            event['frameSequence'] = action['frameSequence']
        events.append(event)
    frames = []
    for i in range(16):
        frames.append(dict(commit=dict(frame=dict(phase='prefill', sequence=i,
            tokenOffset=i*512, tokenCount=512, finalPromptChunk=i == 15), committedTokens=(i+1)*512),
            exactEnvelopeJSON='{}', envelopeFingerprint='1'*64, envelopeWireBytesSHA256='2'*64))
    execution = dict(kind='qwen_long_prefill_rank_request', schemaVersion=1,
        correctnessOnly=True, throughputMeasurementValid=False, interprocessTransportUsed=True,
        physicalTransferQualified=False, independentNumericalComparisonPerformed=False,
        profile=agreement['profile'], profileFingerprint=agreement['profileFingerprint'],
        agreementFingerprint=report['agreementFingerprint'], identity={}, readiness={}, frames=frames,
        actions=actions, selectedTokenID=271, exactTokenPacketJSON='{}', tokenPacketFingerprint='3'*64,
        tokenPacketWireBytesSHA256='4'*64, finalDigest={}, completedFrames=16, committedTokens=8192,
        preparedAheadFrames=15 if rank == 0 and agreement['schedulingPolicy'] == 'prompt_lookahead_one_v1' else 0,
        releasedOriginalBoundaryHandles=16, postStopReleaseCompleted=True, allRequestStateRetired=True,
        originalWrapperReleaseIsNotProofOfNoStorageAliases=True)
    if rank == 0:
        times = {e['phase']: e['localUptimeNanoseconds'] for e in events if 'frameSequence' not in e}
        start, stop = times['readiness.completed'], times['control.tokenValidated']
        execution['timing'] = dict(timing_flags(), startUptimeNanoseconds=start,
            stopUptimeNanoseconds=stop, elapsedNanoseconds=stop-start,
            promptTokensPerFirstTokenSecond=8192e9/float(stop-start),
            postStopThroughRequestCloseNanoseconds=times['requestClosed']-stop)
    else:
        execution['localSelection'] = {}
    report['execution'] = execution
    trace = dict(kind='qwen_prefill_local_phase_trace', schemaVersion=1,
        identity=dict(requestFingerprint=report['request']['fingerprint'], profile=agreement['profile'],
                      role='rank'+str(rank)), clockSource='DispatchTime.uptimeNanoseconds', maximumEvents=512,
        events=events, firstLocalUptimeNanoseconds=events[0]['localUptimeNanoseconds'],
        lastLocalUptimeNanoseconds=events[-1]['localUptimeNanoseconds'],
        traceSpanNanoseconds=events[-1]['localUptimeNanoseconds']-events[0]['localUptimeNanoseconds'],
        diagnosticOnly=True, includesRecorderOverhead=True, crossProcessClockAlignmentAsserted=False,
        gpuOverlapAsserted=False, modelReleaseAsserted=False, recorderIndependentlyVerifiesRequestRetirement=False)
    return report, trace
