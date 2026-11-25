"""Independent CPU oracle for bounded v3 serial/lookahead prefill rank records.

The reference exports vocabulary values; the new ranks do not. Current rank
logits are checked by metadata/SHA agreement, with no native byte-comparison
assertion inferred. Timing validates arithmetic and source-bound phase order,
not a performance qualification or independent observation of clock reads.
"""
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import re
import struct
import sys
import uuid

PREFILL_HELPER_SHA = '4bc20dfff992f6c7c8085a8f60bb565b34d883e6a9578e79db8c8ef963bc494c'
REFERENCE_SHA = '10971a2556dbbfecf6557ba67375646a035483b4c3cbe937a67b7f22adfb8597'
REFERENCE_CANONICAL_SHA = '1211dd97e2a9219c942f0588326bdd2aa4262be0c365c4090cb666731bbbfa9f'
EXPECTED_SHA = '6561d53690bb31effdd20a164417df3ebd70f32add9d0b0508ac03df1e7c2717'
FLOW = 'bounded_prefill_measurement_v1'
POLICIES = ('serial_v1', 'prompt_lookahead_one_v1')
FRONTIERS = (32, 64, 65)
SELECTION = 'mlx_argmax_all_axes_with_finite_guard_v1'
_PREFILL = None


def require(ok, message):
    if not ok: raise ValueError(message)


def digest(data): return hashlib.sha256(data).hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False, allow_nan=False).encode()


def prefill_helper():
    global _PREFILL
    if _PREFILL is None:
        path = Path(__file__).with_name('qwen_layer_stage_prefill_audit.py')
        require(digest(path.read_bytes()) == PREFILL_HELPER_SHA, 'Frozen one-process prefill oracle changed')
        spec = importlib.util.spec_from_file_location('rank_prefill_reference_oracle', path)
        _PREFILL = importlib.util.module_from_spec(spec); spec.loader.exec_module(_PREFILL)
    return _PREFILL


def exact(actual, expected, label='record'):
    prefill_helper().exact(actual, expected, label)


def bounded_json(data, maximum):
    require(type(data) is bytes and 0 < len(data) <= maximum, 'Empty/oversized JSON')
    depth, quoted, escaped = 0, False, False
    for byte in data:
        if quoted:
            if escaped: escaped = False
            elif byte == 92: escaped = True
            elif byte == 34: quoted = False
        elif byte == 34: quoted = True
        elif byte in (123, 91):
            depth += 1; require(depth <= 16, 'JSON depth exceeds bound')
        elif byte in (125, 93):
            depth -= 1; require(depth >= 0, 'Unbalanced JSON')
    require(depth == 0 and not quoted, 'Unterminated JSON')
    try: value = prefill_helper().base_helper().parse_json(data.decode('utf-8'))
    except (UnicodeError, json.JSONDecodeError, RecursionError) as error:
        raise ValueError('Malformed JSON') from error
    require(type(value) is dict, 'Expected JSON object')
    return value


def read_rank_rows(path):
    with Path(path).open('rb') as stream: data = stream.read(4 * 1024**2 + 1)
    require(0 < len(data) <= 4 * 1024**2, 'Rank JSONL exceeds 4 MiB bound')
    lines = data.splitlines()
    require(len(lines) == 2 and all(lines), 'Rank must contain exactly ready then terminal')
    return [bounded_json(line, 4 * 1024**2) for line in lines], digest(data)


def fresh_request(reference, epoch):
    require(type(epoch) is str and re.fullmatch('[0-9a-f]{32}', epoch), 'Epoch must be lowercase HEX32')
    uid = uuid.UUID(hex=epoch)
    require(uid != uuid.UUID(reference['request']['requestID']), 'Fresh rank cohort reused reference UUID')
    simple = digest(f'qwen-stage-request-v1|{uid}|65|32|1'.encode())
    prompt = reference['promptTokenIDs']
    recorded = digest(('qwen-layer-stage-recorded-request-v1\n' + simple + '\nvocabulary=248320\nprompt='
        + ','.join(map(str, prompt)) + '\nteacher=').encode())
    request = dict(reference, request=dict(reference['request'], requestID=str(uid).upper()), fingerprint=recorded)
    return request, simple


def agreement_descriptor(request, simple, loads, epoch, policy):
    require(policy in POLICIES, 'Unsupported local scheduling policy')
    first, second = loads
    return dict(version=3, flow=FLOW, schedulingPolicy=policy, epoch=epoch,
        requestID=request['request']['requestID'].lower(), requestFingerprint=simple,
        recordedRequestFingerprint=request['fingerprint'], promptCount=65, chunkSize=32, outputCount=1,
        batchSize=1, frameCount=3, promptTokenIDsSHA256=digest(','.join(map(str, request['promptTokenIDs'])).encode()),
        sourceConfigurationSHA256=first['sourceConfigurationSHA256'], artifactAggregateSHA256=first['verifiedAggregateSHA256'],
        storageCommitmentSHA256=first['storageCommitmentSHA256'], planFingerprint=first['planSHA256'],
        producerStageFingerprint=first['stagePlanSHA256'], consumerStageFingerprint=second['stagePlanSHA256'],
        producerConstructionConfigurationSHA256=first['constructionConfigurationSHA256'],
        consumerConstructionConfigurationSHA256=second['constructionConfigurationSHA256'], bf16ConversionEnabled=True,
        hiddenSize=4096, nativeDType='bfloat16', logitsDType='bfloat16', vocabularySize=248320, selectionPolicy=SELECTION)


def agreement_hash(descriptor):
    return digest(b'qwen-prefill-start-agreement-v1\n' + canonical(descriptor))


def envelope_value(step, descriptor, agreement, payload):
    frame = step['frame']
    header = dict(version=1, requestFingerprint=descriptor['requestFingerprint'],
        sourceConfigurationSHA256=descriptor['sourceConfigurationSHA256'], artifactAggregateSHA256=descriptor['artifactAggregateSHA256'],
        storageCommitmentSHA256=descriptor['storageCommitmentSHA256'], planFingerprint=descriptor['planFingerprint'],
        producerStageFingerprint=descriptor['producerStageFingerprint'], frame=frame,
        tokenIDsSHA256=digest(','.join(map(str, step['tokenIDs'])).encode()), payloadSHA256=payload,
        shape=[1, frame['tokenCount'], 4096], dtype='bfloat16', byteCount=frame['tokenCount'] * 4096 * 2)
    return dict(version=3, flow=FLOW, kind='boundary', agreementFingerprint=agreement, boundary=header)


def token_value(request, descriptor, agreement, final_envelope_hash, token):
    return dict(version=3, flow=FLOW, kind='first_selected_token', agreementFingerprint=agreement, epoch=descriptor['epoch'],
        requestFingerprint=descriptor['requestFingerprint'], recordedRequestFingerprint=request['fingerprint'],
        consumerStageFingerprint=descriptor['consumerStageFingerprint'], finalBoundaryEnvelopeSHA256=final_envelope_hash,
        frame=request['steps'][2]['frame'], committedTokens=65, vocabularySize=248320, tokenOrdinal=0,
        selectionPolicy=SELECTION, tokenID=token, logitsShape=[1, 248320], logitsDType='bfloat16',
        selectionDType='uint32', allLogitsFinite=True)


def ack_payload_hash(text):
    return digest(struct.pack('<64i', *digest(text.encode()).encode()))


def expected_actions(rank, policy):
    """Declarative phase/frontier schedule, never inferred from reported actions."""
    require(rank in (0, 1) and policy in POLICIES, 'Wrong trace rank/policy')
    actions = []
    def add(action, native, complete, prepared=0, pending=0, frame=None):
        item = dict(ordinal=len(actions), action=action, nativeCommittedTokens=native,
            completedBoundaryCount=complete, explicitPreparedBoundarySlots=prepared, pendingConsumedFrameSlots=pending)
        if frame is not None: item['frameSequence'] = frame
        actions.append(item)
    def prepare(index, complete, pending):
        add('prepare.begin', 0 if index == 0 else FRONTIERS[index - 1], complete, pending=pending, frame=index)
        add('prepare.committed', FRONTIERS[index], complete, prepared=1, pending=pending, frame=index)
    if rank == 0:
        add('control.beginStartSend', 0, 0); add('control.startSendCompleted', 0, 0); add('freshContextCreated', 0, 0)
        for index, frontier in enumerate(FRONTIERS):
            if policy == 'serial_v1' or index == 0: prepare(index, index, 0)
            for name in ['beginHeader', 'headerSendCompleted', 'readyACKAccepted', 'beginPayloadSend', 'payloadSendCompleted']:
                add('send.' + name, frontier, index, prepared=1, frame=index)
            add('send.receivedACKAccepted', frontier, index, prepared=1, pending=1, frame=index)
            add('producerBoundaryReleased', frontier, index, pending=1, frame=index)
            ahead = policy == 'prompt_lookahead_one_v1' and index < 2
            if ahead: prepare(index + 1, index, 1)
            native = FRONTIERS[index + 1] if ahead else frontier
            add('send.beginConsumedDrain', native, index, prepared=int(ahead), pending=1, frame=index)
            add('send.consumedACKAccepted', native, index + 1, prepared=int(ahead), frame=index)
            add('frameCompleted', native, index + 1, prepared=int(ahead), frame=index)
        for name in ['control.beginTokenReceive', 'control.tokenValidated', 'firstTokenStopRecorded',
                'control.beginPostStopSend', 'control.postStopSendCompleted', 'postStopDiagnostics.begin', 'requestClosed']:
            add(name, 65, 3)
    else:
        add('control.beginStartReceive', 0, 0); add('control.startValidated', 0, 0); add('freshContextCreated', 0, 0)
        before = ['beginHeaderReceive', 'headerValidated', 'beginReadyACK', 'readyACKSendCompleted',
            'beginPayloadReceive', 'payloadReceivedAndValidated', 'beginReceivedACK', 'receivedACKSendCompleted', 'beginConsumption']
        for index, frontier in enumerate(FRONTIERS):
            offset = 0 if index == 0 else FRONTIERS[index - 1]
            for name in before: add('receive.' + name, offset, index, frame=index)
            for name in ['consumptionAndSelectionValidated', 'consumedBoundaryReleased', 'beginConsumedACK']:
                add('receive.' + name, frontier, index, frame=index)
            add('receive.consumedACKSendCompleted', frontier, index + 1, frame=index)
            add('frameCompleted', frontier, index + 1, frame=index)
        for name in ['control.beginTokenSend', 'control.tokenSendCompleted', 'control.beginPostStopReceive',
                'control.postStopValidated', 'postStopDiagnostics.begin', 'requestClosed']:
            add(name, 65, 3)
    require(len(actions) == (46 if rank == 0 else 51), 'Internal fixed trace count differs')
    return actions


def check_timing(timing):
    fixed = dict(clock='DispatchTime.uptimeNanoseconds_rank_zero_only', startEvent='before_start_send_and_fresh_context_creation',
        stopEvent='after_final_consumed_and_selected_token_validation', diagnosticOnly=True,
        includesModelLoading=False, includesPreparedTokenDistribution=False, includesFreshRequestState=True,
        includesBoundaryValidationAndCopies=True, includesScalarTraceRecording=True, includesFinalTokenSelectionAndReturn=True,
        includesFinalDiagnosticCaptures=False, includesPostStopAcknowledgement=False, includesRequestRetirement=False)
    numbers = {'startUptimeNanoseconds', 'stopUptimeNanoseconds', 'elapsedNanoseconds', 'promptTokensPerFirstTokenSecond',
        'postStopThroughRequestCloseNanoseconds'}
    require(type(timing) is dict and set(timing) == set(fixed) | numbers, 'Timing exact fields differ')
    exact({key: timing[key] for key in fixed}, fixed, 'timing scope/events')
    for key in numbers - {'promptTokensPerFirstTokenSecond'}:
        require(type(timing[key]) is int and 0 <= timing[key] <= 2**64 - 1, 'Invalid UInt64 timing value')
    start, stop, elapsed = (timing[k] for k in ['startUptimeNanoseconds', 'stopUptimeNanoseconds', 'elapsedNanoseconds'])
    require(0 < start < stop and elapsed == stop - start and 0 < elapsed <= 180_000_000_000,
        'Clock order/duration differs or exceeds admitted deadline')
    post = timing['postStopThroughRequestCloseNanoseconds']
    require(post <= 180_000_000_000 and stop + post <= 2**64 - 1, 'Post-stop duration outside admitted bounds')
    rate = timing['promptTokensPerFirstTokenSecond']
    require(type(rate) in (int, float) and math.isfinite(rate) and rate == 65.0 * 1e9 / float(elapsed),
        'Diagnostic first-token rate arithmetic differs')
    return dict(elapsedNanoseconds=elapsed, diagnosticPromptTokensPerFirstTokenSecond=rate,
        postStopThroughRequestCloseNanoseconds=post, clockReadPlacementEvidence='Source-bound trace order; clock reads are not independently observed.')


def validate_reports(rank_rows, reference_rows, expected, epoch, policy, reference_sha=REFERENCE_SHA):
    require(reference_sha == REFERENCE_SHA, 'Wrong separately frozen one-process reference')
    require(digest(canonical(expected)) == EXPECTED_SHA, 'Independent real9B inventory changed')
    require(type(reference_rows) is list and len(reference_rows) == 2, 'Reference checkpoint/report missing')
    require(digest(canonical(reference_rows)) == REFERENCE_CANONICAL_SHA, 'Frozen reference record contents changed')
    prefill = prefill_helper(); base = prefill.base_helper()
    reference_check = prefill.check_prefill_pair(reference_rows[0], reference_rows[1], expected)
    reference = reference_rows[0]['baseline']; loads = reference_rows[1]['stageLoads']
    request, simple = fresh_request(reference['request'], epoch)
    descriptor = agreement_descriptor(request, simple, loads, epoch, policy); agreement = agreement_hash(descriptor)
    identities = [prefill.session_identity(load, rank, simple) for rank, load in enumerate(loads)]
    require(type(rank_rows) is list and len(rank_rows) == 2, 'Two ordered rank record lists required')
    reports = []
    for rank, rows in enumerate(rank_rows):
        require(type(rows) is list and len(rows) == 2, 'Missing rank ready or terminal record')
        ready, report = rows
        common = dict(schemaVersion=1, epoch=epoch, rank=rank, worldSize=2, transport='loopback-test', backend='ring',
            flow=FLOW, envelopeVersion=3, agreementFingerprint=agreement, agreement=descriptor)
        exact(ready, dict(kind='qwen_layer_stage_prefill_rank_ready', modelsReadyAgreementValidated=True,
            freshRequestStateCreated=False, **common), f'rank{rank}.ready')
        terminal = set(common) | {'kind', 'completed', 'correctnessOnly', 'throughputMeasurementValid', 'modelForwardCompared',
            'physicalTransferQualified', 'sourceLoad', 'request', 'execution', 'allRequestStateRetired', 'modelReleased',
            'conservativeStateAndBoundaryBytes', 'memory'}
        require(type(report) is dict and set(report) == terminal, 'Rank terminal exact fields differ')
        exact({key: report[key] for key in common}, common, f'rank{rank}.identity')
        exact(report['kind'], 'qwen_layer_stage_prefill_rank_report', 'rank report kind')
        base.flags(report, completed=True, correctnessOnly=True, throughputMeasurementValid=False,
            modelForwardCompared=False, physicalTransferQualified=False, allRequestStateRetired=True, modelReleased=True)
        exact(report['sourceLoad'], loads[rank], f'rank{rank}.complete source load')
        exact(report['request'], request, f'rank{rank}.exact prompt history')
        exact(report['conservativeStateAndBoundaryBytes'], reference_rows[1]['conservativeStateAndBoundaryBytes'], 'State/boundary admission')
        phases = ['before_stage_load', 'stage_loaded_no_request_state', 'stage_request_retired_weights_resident',
            'stage_model_released_cache_cleared']
        memory = report['memory']; require(type(memory) is list and len(memory) == 4, 'Rank memory phase coverage differs')
        peak = 0
        for observation, phase in zip(memory, phases):
            require(type(observation) is dict and set(observation) == {'phase', 'activeMLXBytes', 'cachedMLXBytes', 'peakMLXBytesSinceProcessStart'},
                'Rank memory fields differ')
            exact(observation['phase'], phase, 'rank memory phase')
            for key in ['activeMLXBytes', 'cachedMLXBytes', 'peakMLXBytesSinceProcessStart']: base.integer(observation[key])
            require(observation['peakMLXBytesSinceProcessStart'] >= max(peak, observation['activeMLXBytes']), 'MLX peak accounting differs')
            peak = observation['peakMLXBytesSinceProcessStart']
        exact(memory[-1]['cachedMLXBytes'], 0, 'Final rank cache clearance')
        execution = report['execution']
        keys = {'kind', 'agreementFingerprint', 'identity', 'frames', 'actions', 'selectedTokenID', 'exactTokenPacketJSON',
            'tokenPacketSHA256', 'finalStateEntries', 'finalStateLogicalBytes', 'finalStateSHA256', 'completedFrames',
            'committedTokens', 'preparedAheadFrames', 'releasedOriginalBoundaryHandles', 'perFrameStateSnapshots', 'perFrameLogitCaptures',
            'finalStateSnapshots', 'finalLogitCaptures', 'localTokenSelections', 'postStopReleaseCompleted', 'allRequestStateRetired'}
        keys |= {'timing'} if rank == 0 else {'localSelection', 'finalLogits'}
        require(type(execution) is dict and set(execution) == keys, 'Rank execution exact role/schema differs')
        exact(execution['kind'], 'qwen_layer_stage_prefill_rank_request', 'execution kind')
        exact(execution['agreementFingerprint'], agreement, 'execution agreement')
        exact(execution['identity'], identities[rank], 'execution stage identity')
        for key, value in dict(completedFrames=3, committedTokens=65,
                preparedAheadFrames=2 if rank == 0 and policy == 'prompt_lookahead_one_v1' else 0,
                releasedOriginalBoundaryHandles=3, perFrameStateSnapshots=0, perFrameLogitCaptures=0,
                finalStateSnapshots=1, finalLogitCaptures=rank, localTokenSelections=rank,
                postStopReleaseCompleted=True, allRequestStateRetired=True).items(): exact(execution[key], value, 'execution.' + key)
        actions = expected_actions(rank, policy); exact(execution['actions'], actions, f'rank{rank}.exact phase/frontier trace')
        expected_entries = [e for e in reference['frames'][2]['state']['entries'] if rank * 16 <= e['globalLayerIndex'] < (rank + 1) * 16]
        require(len(expected_entries) == 36, 'Reference stage component split differs')
        exact(execution['finalStateEntries'], expected_entries, 'rank final state metadata/SHA')
        exact(execution['finalStateLogicalBytes'], sum(e['byteCount'] for e in expected_entries), 'rank final state bytes')
        exact(execution['finalStateSHA256'], prefill.state_hash(expected_entries, 65), 'rank global-index state fingerprint')
        require(type(execution['frames']) is list and len(execution['frames']) == 3, 'Rank frame count differs')
        reports.append(report)
    # The reference oracle rederived all canonical source/stage inventories. Rank
    # receipts above must match them in full, including every inert descriptor.
    base.stage_inventory(reference['source'], [r['sourceLoad'] for r in reports], expected)
    envelopes, frame_summaries = [], []
    for index, step in enumerate(request['steps']):
        pair = []
        for rank, report in enumerate(reports):
            frame = report['execution']['frames'][index]
            require(type(frame) is dict and set(frame) == {'commit', 'exactEnvelopeJSON', 'envelopeSHA256'}, 'Frame exact fields differ')
            kind = 'hidden' if rank == 0 else ('logits' if index == 2 else 'evaluation_handle')
            shape = [1, step['frame']['tokenCount'], 4096] if rank == 0 else ([1, 248320] if index == 2 else [1, 1])
            exact(frame['commit'], dict(identity=identities[rank], recordedRequestFingerprint=request['fingerprint'], frame=step['frame'],
                committedTokens=FRONTIERS[index], outputKind=kind, outputShape=shape, outputDType='bfloat16'), 'native frame commit')
            require(type(frame['exactEnvelopeJSON']) is str, 'Raw envelope must be text')
            raw = frame['exactEnvelopeJSON'].encode('utf-8'); value = bounded_json(raw, 16 * 1024)
            require(type(value.get('boundary')) is dict, 'Missing nested v1 boundary')
            payload = base.sha_string(value['boundary'].get('payloadSHA256'))
            expected_envelope = envelope_value(step, descriptor, agreement, payload)
            exact(value, expected_envelope, 'v3 envelope exact source/token/geometry')
            require(raw == canonical(expected_envelope), 'Sender-generated envelope is not exact canonical bytes')
            exact(frame['envelopeSHA256'], digest(raw), 'raw envelope fingerprint')
            pair.append(raw)
        require(pair[0] == pair[1], 'Both ranks did not retain identical actual envelope bytes')
        envelopes.append(pair[0]); env_hash = digest(pair[0])
        frame_summaries.append(dict(committedTokens=FRONTIERS[index], envelopeSHA256=env_hash,
            boundaryPayloadSHA256=json.loads(pair[0])['boundary']['payloadSHA256'], boundaryByteCount=step['frame']['tokenCount'] * 8192,
            expectedACKPayloadSHA256={phase: ack_payload_hash(f'qwen-stage-ack-v3|{FLOW}|{agreement}|{phase}|{env_hash}')
                for phase in ['ready', 'received', 'consumed']}))
    token = reference_check['argmaxTokenID']
    expected_packet = token_value(request, descriptor, agreement, digest(envelopes[2]), token)
    packet_bytes = canonical(expected_packet)
    for report in reports:
        execution = report['execution']
        exact(execution['selectedTokenID'], token, 'selected target token vs reference argmax')
        require(type(execution['exactTokenPacketJSON']) is str, 'Raw token packet must be text')
        raw = execution['exactTokenPacketJSON'].encode('utf-8')
        exact(bounded_json(raw, 4 * 1024), expected_packet, 'first-token packet exact semantics')
        require(raw == packet_bytes, 'Actual token packet differs from source-generated canonical bytes')
        exact(execution['tokenPacketSHA256'], digest(raw), 'actual token packet SHA')
    final = request['steps'][2]['frame']; consumer = reports[1]['execution']
    exact(consumer['localSelection'], dict(kind='qwen_layer_stage_prefill_local_token', identity=identities[1],
        recordedRequestFingerprint=request['fingerprint'], frame=final, committedTokens=65, vocabularySize=248320,
        outputOrdinal=0, selectionPolicy=SELECTION, tokenID=token, logitsShape=[1, 248320], logitsDType='bfloat16',
        selectionDType='uint32', allLogitsFinite=True), 'actual local native selection receipt')
    exact(consumer['finalLogits'], dict(kind='qwen_layer_stage_prefill_final_logits', identity=identities[1],
        recordedRequestFingerprint=request['fingerprint'], frame=final, committedTokens=65, vocabularySize=248320,
        shape=[1, 248320], dtype='bfloat16', byteCount=496640, logicalBytesSHA256=reference_check['finalNativeLogitsSHA256']),
        'candidate final logit metadata/digest agreement')
    union = sorted(reports[0]['execution']['finalStateEntries'] + consumer['finalStateEntries'], key=lambda e: (e['globalLayerIndex'], e['component']))
    exact(union, reference['frames'][2]['state']['entries'], 'complete final state union')
    union_hash = prefill.state_hash(union, 65); exact(union_hash, reference['frames'][2]['state']['fingerprint'], 'union state fingerprint')
    timing = check_timing(reports[0]['execution']['timing'])
    start_packet = canonical(dict(version=3, flow=FLOW, kind='start', agreementFingerprint=agreement, agreement=descriptor))
    return dict(status='passed', policy=policy, epoch=epoch, agreementFingerprint=agreement,
        requestFingerprint=simple, recordedRequestFingerprint=request['fingerprint'], actionCounts=[46, 51],
        actionTraceSHA256=[digest(canonical(r['execution']['actions'])) for r in reports], completedFramesPerRank=[3, 3],
        frames=frame_summaries, expectedStartPacketSHA256=digest(start_packet),
        expectedReadinessACKPayloadSHA256=ack_payload_hash('qwen-prefill-readiness-v1|' + agreement),
        exactFirstTokenPacketSHA256=digest(packet_bytes),
        expectedPostStopACKPayloadSHA256=ack_payload_hash(f'qwen-prefill-post-stop-v1|{FLOW}|{agreement}|post_stop_release|{digest(packet_bytes)}'),
        argmaxTokenID=token, maximumLogit=reference_check['maximumLogit'], maximumTieCount=reference_check['maximumTieCount'],
        finalStateComponentsPerRank=[36, 36], finalStateComponentsCombined=72,
        finalStateLogicalBytes=sum(e['byteCount'] for e in union), finalStateSHA256=union_hash,
        finalLogitSHA256=reference_check['finalNativeLogitsSHA256'], finalLogitEvidence='Candidate metadata and digest agreement with independently reconstructed reference BF16 bytes.',
        independentlyReconstructedReferenceLogitRows=1, independentlyReconstructedCandidateLogitRows=0,
        currentRankNativePrivateByteComparisonReported=False, currentRankRawStateValuesAvailable=False,
        intermediateCandidateStateCaptures=0, intermediateCandidateLogitCaptures=0,
        inventory=reference_check['inventory'], timing=timing, throughputQualified=False, physicalTwoMachineExecution=False,
        simultaneousGPUExecutionQualified=False, nativePostStopAndRetirementAssertionsChecked=True,
        limitations=[
            'The reference exports one full finite BF16 row; current ranks export only final logit metadata/SHA. Current rank mode makes no native private-byte comparison assertion.',
            'Final state evidence is the complete disjoint metadata/SHA union. No current raw state bytes or intermediate state/logit snapshots are exported.',
            'Exact envelope/token bytes are exported and independently validated. ACK bytes are not exported; generated ACK digests are expectations bound to source-reported completed phase events.',
            'Clock arithmetic and source-bound trace order are checked; clock-read placement, native commits and cleanup are native assertions, not independently observed CPU events.',
            'The reported diagnostic rate includes fresh state, validation/copy/fence, scalar trace and first-token return costs. It establishes no speedup, simultaneous GPU execution or physical-network performance.',
            'Released original array-wrapper counts do not prove absence of every native-storage alias. Cohort uniqueness beyond the pinned reference remains an external coordinator responsibility.'])


def validate(paths, reference_path, expected_path, epoch, policy):
    require(type(paths) in (list, tuple) and len(paths) == 2, 'Provide rank0 and rank1 stdout paths')
    rows, hashes = [], []
    for path in paths:
        result, pin = read_rank_rows(path); rows.append(result); hashes.append(pin)
    prefill = prefill_helper(); reference_rows, reference_sha = prefill.read_rows(reference_path)
    require(reference_sha == REFERENCE_SHA, 'Reference stdout file pin changed')
    if isinstance(expected_path, (str, Path)):
        with Path(expected_path).open('rb') as stream: data = stream.read(4 * 1024**2 + 1)
        expected = bounded_json(data, 4 * 1024**2)
    else: expected = expected_path
    result = validate_reports(rows, reference_rows, expected, epoch, policy, reference_sha)
    result.update(rankStdoutSHA256=hashes, referenceStdoutSHA256=reference_sha,
        expectedInventoryCanonicalSHA256=EXPECTED_SHA, helperSHA256=digest(Path(__file__).read_bytes()))
    return result


if __name__ == '__main__':
    require(len(sys.argv) == 7, 'Usage: qwen_layer_stage_prefill_rank_audit.py RANK0 RANK1 REFERENCE EXPECTED EPOCH POLICY')
    print(json.dumps(validate(sys.argv[1:3], *sys.argv[3:]), indent=2, sort_keys=True, allow_nan=False))
