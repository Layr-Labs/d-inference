"""Prospective cut12 variant of the frozen short-rank numerical audit."""
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import struct
import sys
import uuid

BASELINE_STDOUT_SHA = '6cfe70e292e0e09bdfa1e8c252251b5898f43ecff6e870729a02a1e406bcb4b9'
BASE_HELPER_SHA = '00e07565fab523fded70caa3aabbcaa2064ede8291e1886e9701b455c446c2fe'
EXPECTED_CANONICAL_SHA = 'b7e0c1110ff919a8b62f496a597145e0b845758dae6268254cd413f183c9c2fe'
EXPLICIT_RANGES = [(0, 12), (12, 32)]
COMPONENT_COUNTS = [27, 45]
MAX_STDOUT_BYTES = 32 * 1024 * 1024
MAX_JSON_DEPTH = 16
_BASE = None


def require(ok, message):
    if not ok:
        raise ValueError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False, allow_nan=False).encode()


def base_helper():
    global _BASE
    if _BASE is None:
        path = Path(__file__).resolve().parent.parent / 'short-stage-cut-audit-draft/qwen_layer_stage_cut12_audit.py'
        require(digest(path.read_bytes()) == BASE_HELPER_SHA, 'Frozen recorded-baseline helper changed')
        spec = importlib.util.spec_from_file_location('rank_audit_recorded_helper', path)
        _BASE = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(_BASE)
    return _BASE


def read_rows(path):
    with Path(path).open('rb') as stream:
        data = stream.read(MAX_STDOUT_BYTES + 1)
    require(0 < len(data) <= MAX_STDOUT_BYTES, 'Rank/baseline stdout empty or oversized')
    lines = data.splitlines()
    require(len(lines) == 2 and all(lines), 'Expected exactly ready/checkpoint then terminal JSONL')
    rows = []
    for line in lines:
        depth, quoted, escaped = 0, False, False
        for ch in line:
            if quoted:
                if escaped: escaped = False
                elif ch == 92: escaped = True
                elif ch == 34: quoted = False
            elif ch == 34: quoted = True
            elif ch in (123, 91):
                depth += 1
                require(depth <= MAX_JSON_DEPTH, 'JSON depth exceeds bound')
            elif ch in (125, 93):
                depth -= 1
                require(depth >= 0, 'Unbalanced JSON')
        require(depth == 0 and not quoted, 'Unterminated JSON')
        try:
            value = base_helper().parse_json(line.decode('utf-8'))
        except (UnicodeError, json.JSONDecodeError, RecursionError) as error:
            raise ValueError('Malformed rank JSON') from error
        require(type(value) is dict, 'Expected JSON object')
        rows.append(value)
    return rows, digest(data)


def exact(actual, expected, path='record'):
    require(type(actual) is type(expected), 'Wrong JSON type at ' + path)
    if isinstance(expected, dict):
        require(set(actual) == set(expected), 'Wrong exact fields at ' + path)
        for key, value in expected.items(): exact(actual[key], value, path + '.' + key)
    elif isinstance(expected, list):
        require(len(actual) == len(expected), 'Wrong list length at ' + path)
        for index, value in enumerate(expected): exact(actual[index], value, path + f'[{index}]')
    else:
        require(actual == expected, 'Value or identity differs at ' + path)


def fresh_request(old_request, epoch):
    require(type(epoch) is str and re.fullmatch('[0-9a-f]{32}', epoch), 'Epoch must be lowercase HEX32')
    request_id = uuid.UUID(hex=epoch)
    require(request_id != uuid.UUID(old_request['request']['requestID']), 'Fresh cohort must not reuse prior baseline UUID')
    simple = digest(f'qwen-stage-request-v1|{request_id}|65|32|4'.encode())
    prompt, teacher = old_request['promptTokenIDs'], old_request['teacherTokenIDs']
    recorded = digest(('qwen-layer-stage-recorded-request-v1\n' + simple + '\nvocabulary=248320\nprompt='
        + ','.join(map(str, prompt)) + '\nteacher=' + ','.join(map(str, teacher))).encode())
    expected = dict(old_request, request=dict(old_request['request'], requestID=str(request_id).upper()), fingerprint=recorded)
    return expected, simple, recorded


def state_hash(entries, tokens):
    identities = [f"{x['globalLayerIndex']}|{x['component']}|{x['shape']}|{x['dtype']}|{x['byteCount']}|{x['sha256']}" for x in entries]
    return digest(('cbv2-owned-state-v1\ntokens=' + str(tokens) + '\n' + '\n'.join(identities)).encode())


def session_identity(load, rank, simple_request):
    return dict(stageIndex=rank, requestFingerprint=simple_request, artifactAggregateSHA256=load['verifiedAggregateSHA256'],
        storageCommitmentSHA256=load['storageCommitmentSHA256'], bf16ConversionEnabled=load['bf16ConversionEnabled'],
        sourceConfigurationSHA256=load['sourceConfigurationSHA256'],
        constructionConfigurationSHA256=load['constructionConfigurationSHA256'], planFingerprint=load['planSHA256'],
        stageFingerprint=load['stagePlanSHA256'], activationDType=load['embeddingActivationDType'])


def header_bytes(load0, simple_request, step, payload_hash):
    tokens, frame = step['tokenIDs'], step['frame']
    value = dict(version=1, requestFingerprint=simple_request,
        sourceConfigurationSHA256=load0['sourceConfigurationSHA256'], artifactAggregateSHA256=load0['verifiedAggregateSHA256'],
        storageCommitmentSHA256=load0['storageCommitmentSHA256'], planFingerprint=load0['planSHA256'],
        producerStageFingerprint=load0['stagePlanSHA256'], frame=frame,
        tokenIDsSHA256=digest(','.join(map(str, tokens)).encode()), payloadSHA256=payload_hash,
        shape=[1, frame['tokenCount'], 4096], dtype='bfloat16', byteCount=frame['tokenCount'] * 4096 * 2)
    encoded = canonical(value)
    require(0 < len(encoded) <= 16384, 'Expected wire header exceeds bound')
    return encoded


def ack_hash(header, phase):
    values = digest(f'qwen-stage-ack-v1|{phase}|{digest(header)}'.encode()).encode()
    return digest(struct.pack('<64i', *values))


def validate_reports(rank_rows, old_rows, epoch, expected, old_sha=BASELINE_STDOUT_SHA):
    """Metadata/capture validator; caller must bind old_rows to old_sha via read_rows."""
    require(old_sha == BASELINE_STDOUT_SHA, 'Reference baseline stdout identity differs')
    require(digest(canonical(expected)) == EXPECTED_CANONICAL_SHA, 'Independent real9B expected metadata changed')
    base = base_helper()
    old_checkpoint, old_report = old_rows
    baseline_validation = base.check_recorded_pair(old_checkpoint, old_report, expected)
    baseline = old_checkpoint['baseline']
    new_request, simple_request, recorded_request = fresh_request(baseline['request'], epoch)
    require(isinstance(rank_rows, list) and len(rank_rows) == 2, 'Expected two rank record lists')
    reports = []
    for rank, rows in enumerate(rank_rows):
        require(len(rows) == 2, 'Rank omitted ready or terminal record')
        ready, report = rows
        common = dict(schemaVersion=1, epoch=epoch, rank=rank, worldSize=2, transport='loopback-test', backend='ring')
        exact(ready, dict(kind='qwen_layer_stage_rank_ready', **common), f'rank{rank}.ready')
        terminal_keys = set(common) | {'kind', 'completed', 'correctnessOnly', 'throughputMeasurementValid',
            'modelForwardCompared', 'physicalTransferQualified', 'sourceLoad', 'request', 'frames',
            'allRequestStateRetired', 'modelReleased', 'conservativeStateAndBoundaryBytes', 'memory'}
        require(type(report) is dict and set(report) == terminal_keys, 'Rank terminal exact schema differs')
        exact({k: report[k] for k in common}, common, f'rank{rank}.identity')
        require(report['kind'] == 'qwen_layer_stage_rank_report', 'Wrong rank terminal kind')
        base.flags(report, completed=True, correctnessOnly=True, throughputMeasurementValid=False,
            modelForwardCompared=False, physicalTransferQualified=False, allRequestStateRetired=True, modelReleased=True)
        exact(report['sourceLoad'], old_report['stageLoads'][rank], f'rank{rank}.sourceLoad')
        exact(report['request'], new_request, f'rank{rank}.request')
        require(type(report['frames']) is list and len(report['frames']) == 6, 'Rank frame count differs')
        exact(report['conservativeStateAndBoundaryBytes'], old_report['conservativeStateAndBoundaryBytes'], 'State/boundary resource admission differs')
        phases = ['before_stage_load', 'stage_loaded_request_admitted', 'stage_request_retired_weights_resident', 'stage_model_released_cache_cleared']
        memory = report['memory']
        require(isinstance(memory, list) and len(memory) == 4, 'Memory observation count differs')
        for observation, phase in zip(memory, phases):
            require(set(observation) == {'phase', 'activeMLXBytes', 'cachedMLXBytes', 'peakMLXBytesSinceProcessStart'}
                and observation['phase'] == phase, 'Memory phase/schema differs')
            for key in ['activeMLXBytes', 'cachedMLXBytes', 'peakMLXBytesSinceProcessStart']: base.integer(observation[key])
            require(observation['peakMLXBytesSinceProcessStart'] >= observation['activeMLXBytes'], 'Memory peak below active bytes')
        require(memory[-1]['cachedMLXBytes'] == 0, 'Post-release MLX cache was not cleared')
        reports.append(report)
    # The old exact load receipts already passed independent full expected inventory.
    base.stage_inventory(baseline['source'], [r['sourceLoad'] for r in reports], expected)
    frames = []
    for index, old_frame in enumerate(baseline['frames']):
        step = new_request['steps'][index]; frame = step['frame']; tokens = old_frame['committedTokens']
        captures = []
        for rank, report in enumerate(reports):
            completion = report['frames'][index]
            require(set(completion) == {'kind', 'capture', 'headerSHA256', 'completedTransportPhase'}
                and completion['kind'] == 'qwen_layer_stage_rank_frame_completion', 'Completion exact schema differs')
            phase = 'consumed_ack_received_and_validated' if rank == 0 else 'consumed_ack_send_completed'
            require(completion['completedTransportPhase'] == phase, 'Rank ACK phase differs')
            base.sha_string(completion['headerSHA256'])
            capture = completion['capture']; logits_expected = rank == 1 and index >= 2
            keys = {'kind', 'identity', 'frame', 'committedTokens', 'sourceLayerStart', 'sourceLayerEnd', 'stateEntries',
                'logicalStateBytes', 'stageStateSHA256', 'boundaryPayloadSHA256', 'boundaryShape', 'boundaryDType',
                'outputKind', 'outputShape', 'outputDType'} | ({'logits'} if logits_expected else set())
            require(set(capture) == keys and capture['kind'] == 'qwen_layer_stage_rank_frame_capture', 'Capture exact schema differs')
            exact(capture['identity'], session_identity(report['sourceLoad'], rank, simple_request), 'Rank session identity differs')
            for key, value in [('frame', frame), ('committedTokens', tokens), ('sourceLayerStart', EXPLICIT_RANGES[rank][0]), ('sourceLayerEnd', EXPLICIT_RANGES[rank][1])]:
                exact(capture[key], value, 'Rank frame/source range differs: ' + key)
            expected_entries = [entry for entry in old_frame['state']['entries'] if EXPLICIT_RANGES[rank][0] <= entry['globalLayerIndex'] < EXPLICIT_RANGES[rank][1]]
            require(len(expected_entries) == COMPONENT_COUNTS[rank], 'Baseline stage component count differs')
            exact(capture['stateEntries'], expected_entries, 'Rank state metadata/digest differs from baseline')
            expected_bytes = sum(x['byteCount'] for x in expected_entries)
            exact(capture['logicalStateBytes'], expected_bytes, 'Stage state byte count differs')
            require(capture['stageStateSHA256'] == state_hash(expected_entries, tokens), 'Stage state fingerprint differs')
            base.sha_string(capture['boundaryPayloadSHA256'])
            boundary_shape = [1, frame['tokenCount'], 4096]
            exact(capture['boundaryShape'], boundary_shape, 'Native boundary shape differs')
            require(capture['boundaryDType'] == capture['outputDType'] == 'bfloat16', 'Native boundary/output dtype differs')
            kind = 'hidden' if rank == 0 else ('logits' if logits_expected else 'evaluation_handle')
            shape = boundary_shape if rank == 0 else ([1, 248320] if logits_expected else [1, 1])
            require(capture['outputKind'] == kind, 'Rank output kind differs')
            exact(capture['outputShape'], shape, 'Rank output shape differs')
            if logits_expected:
                native = base.logical_bytes(capture['logits'], 248320, 'bfloat16')
                reference = base.logical_bytes(old_frame['logits'], 248320, 'bfloat16')
                require(native == reference, 'Full native rank-one logits differ from frozen baseline bytes')
            captures.append(capture)
        union = sorted(captures[0]['stateEntries'] + captures[1]['stateEntries'], key=lambda x: (x['globalLayerIndex'], x['component']))
        exact(union, old_frame['state']['entries'], 'Combined rank state differs from full baseline')
        union_hash = state_hash(union, tokens)
        require(union_hash == old_frame['state']['fingerprint'], 'Combined state fingerprint differs')
        require(captures[0]['boundaryPayloadSHA256'] == captures[1]['boundaryPayloadSHA256'], 'Cross-rank boundary payload digest differs')
        header = header_bytes(reports[0]['sourceLoad'], simple_request, step, captures[0]['boundaryPayloadSHA256'])
        header_hash = digest(header)
        require(all(r['frames'][index]['headerSHA256'] == header_hash for r in reports), 'Canonical actual-input header digest differs')
        frames.append(dict(committedTokens=tokens, stateEntriesPerStage=list(COMPONENT_COUNTS), stateEntriesCombined=72,
            stageStateBytes=[c['logicalStateBytes'] for c in captures], stageStateSHA256=[c['stageStateSHA256'] for c in captures],
            fullStateSHA256=union_hash, boundaryPayloadSHA256=captures[0]['boundaryPayloadSHA256'],
            boundaryByteCount=frame['tokenCount'] * 4096 * 2, headerSHA256=header_hash,
            expectedReadyACKSHA256=ack_hash(header, 'ready'), expectedConsumedACKSHA256=ack_hash(header, 'consumed'),
            logitValuesCompared=248320 if index >= 2 else 0,
            nativeLogitSHA256=old_frame['logits']['logicalBytesSHA256'] if index >= 2 else None))
    return dict(status='passed', cpuOnly=True, epoch=epoch, rankCount=2, recordedRequestFingerprint=recorded_request,
        simpleRequestFingerprint=simple_request, priorBaselineEvidenceSHA256=baseline['fingerprint'],
        priorBaselineStdoutSHA256=old_sha, priorBaselineIndependentlyRevalidated=True,
        expectedCanonicalMetadataSHA256=EXPECTED_CANONICAL_SHA, frameCount=6, combinedStateEntriesChecked=432,
        exactNativeLogitPairs=4, nativeLogitValuesPerSide=993280, frames=frames,
        stageActiveTensorBytes=[r['sourceLoad']['loadedTensorBytes'] for r in reports],
        stageInertTensorBytes=[r['sourceLoad']['inertTensorBytes'] for r in reports],
        allRequestStateRetiredNativeAssertions=True, modelReleaseNativeAssertions=True,
        sourceLoadReceiptsExactPrior=True, hiddenCutpointComparedToPriorBaseline=False,
        observedBoundaryPayloadBytesAvailable=False, observedACKBytesAvailable=False,
        nativeExecutionsByAudit=0, modelReadsByAudit=0,
        limitations=['Prior and fresh request UUIDs are validated separately; all input tokens, steps, source receipts and native policies remain identical.',
            'Full rank-one BF16 logits are reconstructed from persisted finite Float32 values and compared byte-for-byte with the separately frozen baseline, preserving signed zeros.',
            'State entry metadata and SHA values match the prior full-model baseline; raw state tensors are not exported for CPU replay.',
            'Boundary payload digests match across ranks and bind independently reconstructed headers; the old baseline has no cutpoint capture and raw boundary/ACK bytes are not exported.',
            'Retirement, weak model release and ACK completion are native assertions. Parent must separately bind executable/source identity, process exits and cleanup.',
            'Two local processes over loopback ring; no physical Thunderbolt/RDMA or throughput qualification.'])


def validate(paths, oldbaselinepath, epoch, expected):
    require(isinstance(paths, (list, tuple)) and len(paths) == 2, 'Need ordered rank-zero/rank-one stdout paths')
    old_rows, old_sha = read_rows(oldbaselinepath)
    require(old_sha == BASELINE_STDOUT_SHA, 'Frozen baseline stdout identity differs')
    rank_rows, hashes = [], []
    for path in paths:
        rows, value = read_rows(path); rank_rows.append(rows); hashes.append(value)
    result = validate_reports(rank_rows, old_rows, epoch, expected, old_sha)
    result['rankStdoutSHA256'] = hashes
    result['auditHelperSHA256'] = digest(Path(__file__).read_bytes())
    result['recordedBaselineHelperSHA256'] = BASE_HELPER_SHA
    return result
