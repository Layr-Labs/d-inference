"""CPU comparison of fixed real9B lookahead reports with frozen native evidence."""
import hashlib
import importlib.util
from pathlib import Path
import struct

FLOW = 'prompt_lookahead_one_v1'
RANK_HELPER_SHA = '489a4904d6ba947b33fabd7acf840c5f524bf37835ee2f6b81afaab80e0f0c9a'
_RANK = None


def require(ok, message):
    if not ok: raise ValueError(message)


def sha(data): return hashlib.sha256(data).hexdigest()


def rank_helper():
    global _RANK
    if _RANK is None:
        path = Path(__file__).with_name('qwen_layer_stage_rank_audit.py')
        require(sha(path.read_bytes()) == RANK_HELPER_SHA, 'Frozen serialized-rank helper changed')
        spec = importlib.util.spec_from_file_location('lookahead_serialized_rank_helper', path)
        _RANK = importlib.util.module_from_spec(spec); spec.loader.exec_module(_RANK)
    return _RANK


def wire_identity(source_load, simple_request, step, payload_hash):
    rank = rank_helper()
    inner = rank.header_bytes(source_load, simple_request, step, payload_hash)
    outer = rank.canonical(dict(version=2, flow=FLOW, boundary=rank.base_helper().parse_json(inner.decode())))
    require(0 < len(outer) <= 16384, 'Canonical v2 envelope exceeds byte bound')
    ack_hashes = {}
    for phase in ('ready', 'received', 'consumed'):
        values = sha(f'qwen-stage-ack-v2|{FLOW}|{phase}|{sha(outer)}'.encode()).encode()
        ack_hashes[phase] = sha(struct.pack('<64i', *values))
    return dict(v1HeaderSHA256=sha(inner), envelopeSHA256=sha(outer), envelopeByteCount=len(outer),
        expectedACKLogicalBytesSHA256=ack_hashes)


def expected_actions(rank, steps, header_hashes):
    """Derive fixed host order directly from admitted token frames, not native counters."""
    require(rank in (0, 1) and len(steps) == len(header_hashes) == 6, 'Fixed action timeline requires two ranks and six frames')
    actions = []; produced = received = completed = committed = native = owns = pending = 0
    def frontier(step): return step['frame']['tokenOffset'] + step['frame']['tokenCount']
    def emit(action, activity, sequence=None, ticket=False):
        entry = dict(ordinal=len(actions), action=action, scheduleActivity=activity,
            nativeCommittedTokens=native, completedFrames=completed,
            explicitNativeBoundarySlots=owns, pendingConsumedFrameSlots=pending)
        if sequence is not None: entry['frameSequence'] = sequence
        if ticket: entry['headerSHA256'] = header_hashes[sequence]
        if rank == 0: entry.update(producedFrames=produced, receivedFrames=received)
        else: entry['receiverCommittedFrames'] = committed
        actions.append(entry)
    def prepare(sequence):
        nonlocal produced, native, owns
        emit('beginPreparation', 'preparing', sequence)
        produced += 1; native = frontier(steps[sequence]); owns = 1
        emit('preparationCompleted', 'idle', sequence)
    for sequence, step in enumerate(steps):
        if rank == 0:
            if produced == sequence: prepare(sequence)
            for phase, activity in [('beginHeader', 'sendingHeader'), ('headerSendCompleted', 'awaitingReady'),
                ('readyACKAccepted', 'readyForPayload'), ('beginPayloadSend', 'sendingPayload'),
                ('payloadSendCompleted', 'awaitingReceived')]: emit('send.' + phase, activity, sequence, True)
            received += 1; pending = 1
            emit('send.receivedACKAccepted', 'idle', sequence, True)
            owns = 0; emit('sentSourceReleased', 'idle', sequence, True)
            # Exactly one next PROMPT preparation may occur before this consumed
            # drain. Final prompt and every teacher decode drain immediately.
            if sequence + 1 < len(steps) and steps[sequence + 1]['frame']['phase'] == 'prefill': prepare(sequence + 1)
            emit('send.beginConsumedDrain', 'drainingConsumed', sequence, True)
            completed += 1; pending = 0
            emit('send.consumedACKAccepted', 'idle', sequence, True)
            emit('frameCompletion', 'idle', sequence, True)
        else:
            emit('receive.beginHeaderReceive', 'receivingHeader')
            pending = 1; emit('receive.headerValidated', 'readyForReadyACK', sequence, True)
            for phase, activity in [('beginReadyACK', 'sendingReadyACK'), ('readyACKSendCompleted', 'readyForPayload'),
                ('beginPayloadReceive', 'receivingPayload')]: emit('receive.' + phase, activity, sequence, True)
            owns = 1; emit('receive.payloadReceivedAndValidated', 'readyForReceivedACK', sequence, True)
            for phase, activity in [('beginReceivedACK', 'sendingReceivedACK'), ('receivedACKSendCompleted', 'readyToConsume'),
                ('beginConsumption', 'consuming')]: emit('receive.' + phase, activity, sequence, True)
            native = frontier(step); committed += 1
            emit('receive.consumptionAndCaptureCompleted', 'consumedNeedsRelease', sequence, True)
            owns = 0; emit('receive.consumedBoundaryReleased', 'readyForConsumedACK', sequence, True)
            emit('receive.beginConsumedACK', 'sendingConsumedACK', sequence, True)
            completed += 1; pending = 0
            emit('receive.consumedACKSendCompleted', 'waitingHeader', sequence, True)
            emit('frameCompletion', 'waitingHeader', sequence, True)
    emit('requestClosed', 'closed')
    require(len(actions) == (73 if rank == 0 else 85) and completed == 6 and native == 68
        and owns == pending == 0, 'Independent host timeline coverage differs')
    return actions


def expected_execution_summary(rank, identity, recorded_fingerprint, actions):
    value = dict(kind='qwen_layer_stage_lookahead_request', flow=FLOW, identity=identity,
        recordedRequestFingerprint=recorded_fingerprint, decodeAdmission='frozen_teacher_diagnostic',
        finalCommittedTokens=68, completedFrames=6,
        maximumExplicitNativeBoundarySlots=max(x['explicitNativeBoundarySlots'] for x in actions),
        releasedOriginalArrayHandles=6, allRequestStateRetired=True)
    if rank == 0:
        value.update(producedFrames=6, receivedFrames=6,
            promptLookaheadCount=sum(x['action'] == 'preparationCompleted' and x['pendingConsumedFrameSlots'] == 1 for x in actions),
            maximumProducedMinusReceived=max(x['producedFrames'] - x['receivedFrames'] for x in actions),
            maximumReceivedMinusCompleted=max(x['receivedFrames'] - x['completedFrames'] for x in actions),
            maximumProducedMinusCompleted=max(x['producedFrames'] - x['completedFrames'] for x in actions))
    return value


def _validate_reports(rank_rows, old_rows, epoch, expected, old_sha):
    rank = rank_helper(); exact = rank.exact
    require(type(rank_rows) is list and len(rank_rows) == 2 and all(type(rows) is list and len(rows) == 2 for rows in rank_rows),
        'Expected ready and terminal records for both ranks')
    baseline = old_rows[0]['baseline']; old_report = old_rows[1]
    new_request, simple, recorded = rank.fresh_request(baseline['request'], epoch)
    adapted = []; wires_by_rank = []; traces = []
    for index, rows in enumerate(rank_rows):
        ready, report = rows
        common = dict(schemaVersion=1, epoch=epoch, rank=index, worldSize=2, transport='loopback-test', backend='ring')
        wire_common = dict(flow=FLOW, envelopeVersion=2)
        exact(ready, dict(kind='qwen_layer_stage_lookahead_ready', **common, **wire_common), f'rank{index}.ready')
        terminal_keys = set(common) | set(wire_common) | {'kind', 'completed', 'correctnessOnly', 'throughputMeasurementValid',
            'modelForwardCompared', 'physicalTransferQualified', 'sourceLoad', 'request', 'execution',
            'allRequestStateRetired', 'modelReleased', 'conservativeStateAndBoundaryBytes', 'memory'}
        require(type(report) is dict and set(report) == terminal_keys, 'Lookahead terminal exact fields differ')
        exact({key: report[key] for key in common}, common, 'Lookahead cohort identity')
        exact({key: report[key] for key in wire_common}, wire_common, 'Lookahead flow identity')
        exact(report['kind'], 'qwen_layer_stage_lookahead_report', 'Lookahead terminal kind')
        exact(report['request'], new_request, 'Lookahead input history must equal frozen baseline except fresh UUID')
        execution = report['execution']
        require(type(execution) is dict and type(execution.get('completions')) is list and len(execution['completions']) == 6,
            'Expected one nested execution and six completed frames')
        wires, bare_completions = [], []
        for sequence, completion in enumerate(execution['completions']):
            require(type(completion) is dict and type(completion.get('capture')) is dict, 'Malformed completion/capture')
            payload_hash = completion['capture']['boundaryPayloadSHA256']; rank.base_helper().sha_string(payload_hash)
            wire = wire_identity(old_report['stageLoads'][0], simple, new_request['steps'][sequence], payload_hash)
            exact(completion['headerSHA256'], wire['envelopeSHA256'], 'Actual completion must bind canonical v2 outer bytes')
            wires.append(wire)
            # Only the transport identity is adapted for the frozen numerical
            # oracle. All original capture/source/request/logit values are reused
            # unchanged; original records are never mutated.
            bare_completions.append(dict(completion, headerSHA256=wire['v1HeaderSHA256']))
        actions = expected_actions(index, new_request['steps'], [wire['envelopeSHA256'] for wire in wires])
        exact(execution['actions'], actions, f'rank{index}.hostActionTrace')
        summary = expected_execution_summary(index, rank.session_identity(old_report['stageLoads'][index], index, simple), recorded, actions)
        exact({key: value for key, value in execution.items() if key not in ('actions', 'completions')}, summary,
            f'rank{index}.executionSummary')
        bare_report = {key: value for key, value in report.items() if key not in ('flow', 'envelopeVersion', 'execution')}
        bare_report.update(kind='qwen_layer_stage_rank_report', frames=bare_completions)
        adapted.append([dict(kind='qwen_layer_stage_rank_ready', **common), bare_report])
        wires_by_rank.append(wires); traces.append(actions)
    exact(wires_by_rank[0], wires_by_rank[1], 'Both ranks must bind identical v2 payload/header/ACK identities')
    numerical = rank.validate_reports(adapted, old_rows, epoch, expected, old_sha)
    frames = []
    for original, wire in zip(numerical['frames'], wires_by_rank[0]):
        frame = {key: original[key] for key in ['committedTokens', 'stateEntriesPerStage', 'stateEntriesCombined',
            'stageStateBytes', 'stageStateSHA256', 'fullStateSHA256', 'boundaryPayloadSHA256', 'boundaryByteCount',
            'logitValuesCompared', 'nativeLogitSHA256']}
        frame.update({key: value for key, value in wire.items() if key != 'v1HeaderSHA256'})
        frames.append(frame)
    return dict(status='passed', cpuOnly=True, epoch=epoch, flow=FLOW, envelopeVersion=2,
        frameCount=6, combinedStateEntriesChecked=432, exactNativeLogitPairs=4, nativeLogitValuesPerSide=993280,
        frames=frames, actionCounts=[len(trace) for trace in traces],
        actionTraceSHA256=[sha(rank.canonical(trace)) for trace in traces],
        exactSourceLoadReceiptsComparedToPrior=True, stageActiveTensorBytes=numerical['stageActiveTensorBytes'],
        stageInertTensorBytes=numerical['stageInertTensorBytes'],
        simpleRequestFingerprint=simple, recordedRequestFingerprint=recorded,
        priorBaselineStdoutSHA256=old_sha, priorBaselineEvidenceSHA256=numerical['priorBaselineEvidenceSHA256'],
        expectedCanonicalMetadataSHA256=numerical['expectedCanonicalMetadataSHA256'],
        promptLookaheadPreparations=2, senderMaximumProducedMinusReceived=1, senderMaximumReceivedMinusCompleted=1,
        senderMaximumProducedMinusCompleted=2, maximumExplicitNativeBoundarySlotsPerRank=[1, 1],
        releasedOriginalArrayHandlesNativeAssertions=[6, 6], allRequestStateRetiredNativeAssertions=True,
        modelReleaseNativeAssertions=True, actualACKBytesExported=False, actualEnvelopeBytesExported=False,
        numericalOracleAdapter='Original captures/source/request/logits are passed unchanged to the frozen serialized oracle after renaming outer kinds and supplying separately reconstructed v1 transport header digests. Actual v2 digests/traces are validated first.',
        nativeExecutionsByAudit=0, modelPayloadReadsByAudit=0,
        limitations=['Fixed 65/32/4 real9B request over two local loopback processes; no throughput, physical Thunderbolt or RDMA qualification.',
            'Full native logit values are reconstructed and compared byte-for-byte with the frozen baseline; state comparison uses complete metadata and persisted SHA values, not exported raw state tensors.',
            'CPU reconstructs canonical v2 envelope and all three phase ACK identities; native records export envelope hashes and completion events, not raw envelope/ACK arrays.',
            'The exact per-rank action order establishes the recorded host schedule, not independently measured simultaneous GPU execution or a speedup.',
            'Explicit boundary slots and weak original-array release assertions do not prove absence of every native alias or physical allocator peak.',
            'Retirement, weak model release, wire phase completion and action timing remain source-bound native assertions; parent separately binds executable/source identity, exits and cleanup.'])


def validate_reports(rank_rows, old_rows, epoch, expected, old_sha=None):
    rank = rank_helper()
    try:
        return _validate_reports(rank_rows, old_rows, epoch, expected, old_sha or rank.BASELINE_STDOUT_SHA)
    except (KeyError, TypeError, IndexError) as error:
        raise ValueError('Malformed lookahead evidence structure') from error


def validate(paths, oldbaselinepath, epoch, expected):
    rank = rank_helper()
    require(isinstance(paths, (list, tuple)) and len(paths) == 2, 'Need ordered rank-zero/rank-one stdout paths')
    old_rows, old_sha = rank.read_rows(oldbaselinepath)
    require(old_sha == rank.BASELINE_STDOUT_SHA, 'Frozen baseline stdout identity differs')
    rows_and_hashes = [rank.read_rows(path) for path in paths]
    result = validate_reports([value[0] for value in rows_and_hashes], old_rows, epoch, expected, old_sha)
    result.update(rankStdoutSHA256=[value[1] for value in rows_and_hashes],
        auditHelperSHA256=sha(Path(__file__).read_bytes()), serializedRankHelperSHA256=RANK_HELPER_SHA,
        recordedBaselineHelperSHA256=rank.BASE_HELPER_SHA)
    return result
