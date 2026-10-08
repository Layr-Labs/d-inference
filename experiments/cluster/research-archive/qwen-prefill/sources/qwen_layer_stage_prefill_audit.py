"""CPU-only oracle for the bounded real9B final-observation prefill control.

The candidate exports no vocabulary values. Its final SHA is independently
compared with reconstructed reference bytes; its private byte equality remains
a native assertion. Existing recorded/rank/lookahead helpers stay unchanged.
"""
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import uuid

BASE_HELPER_SHA = 'ba943e3ec2157447d7725ab3ca030bb398813c82be6d4d4a1024d4fbf98d29e4'
BASELINE_STDOUT_SHA = 'dac1248a0b02ffa6010cd641834d2a43e1e7c5e92634bc28613fc7f73aaaf551'
OLD_CHECKPOINT_SHA = '5e5883444d6dd6adb9a0ec3cf4b475688f76cfbc626cc51779f21d381d60495c'
OLD_STAGE_LOADS_SHA = 'cf6671fdaf1613186d8d2973a148e32d4957f6a1a4d699f2fe12b5fa25a9bd1d'
EXPECTED_CANONICAL_SHA = '6561d53690bb31effdd20a164417df3ebd70f32add9d0b0508ac03df1e7c2717'
PROMPT_CANONICAL_SHA = 'efeae75f37c991053666b8e9e27c42f5bd0f04ffab696af958c022054844bd7b'
FRONTIERS = (32, 64, 65)
MAX_STDOUT_BYTES = 32 * 1024**2
_BASE = None


def require(ok, message):
    if not ok: raise ValueError(message)


def digest(data): return hashlib.sha256(data).hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False, allow_nan=False).encode()


def exact(actual, expected, label='record'):
    require(type(actual) is type(expected), 'Wrong type: ' + label)
    if isinstance(expected, dict):
        require(set(actual) == set(expected), 'Wrong fields: ' + label)
        for key, value in expected.items(): exact(actual[key], value, label + '.' + key)
    elif isinstance(expected, list):
        require(len(actual) == len(expected), 'Wrong count: ' + label)
        for index, value in enumerate(expected): exact(actual[index], value, label + f'[{index}]')
    else:
        require(actual == expected, 'Value differs: ' + label)


def base_helper():
    global _BASE
    if _BASE is None:
        path = Path(__file__).with_name('qwen_layer_stage_recorded_audit.py')
        require(digest(path.read_bytes()) == BASE_HELPER_SHA, 'Frozen recorded helper changed')
        spec = importlib.util.spec_from_file_location('prefill_recorded_helper', path)
        _BASE = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(_BASE)
    return _BASE


def read_rows(path):
    """Exactly two bounded JSON objects, retaining Swift's signed integer -0."""
    with Path(path).open('rb') as stream: data = stream.read(MAX_STDOUT_BYTES + 1)
    require(0 < len(data) <= MAX_STDOUT_BYTES, 'Empty/oversized prefill JSONL')
    lines = data.splitlines()
    require(len(lines) == 2 and all(lines), 'Expected checkpoint and terminal report only')
    rows = []
    for line in lines:
        depth, quoted, escaped = 0, False, False
        for byte in line:
            if quoted:
                if escaped: escaped = False
                elif byte == 92: escaped = True
                elif byte == 34: quoted = False
            elif byte == 34: quoted = True
            elif byte in (123, 91):
                depth += 1
                require(depth <= 16, 'JSON depth exceeds bound')
            elif byte in (125, 93):
                depth -= 1
                require(depth >= 0, 'Unbalanced JSON')
        require(depth == 0 and not quoted, 'Unterminated JSON')
        try: value = base_helper().parse_json(line.decode('utf-8'))
        except (UnicodeError, json.JSONDecodeError, RecursionError) as error:
            raise ValueError('Malformed prefill JSON') from error
        require(type(value) is dict, 'Expected JSON object')
        rows.append(value)
    return rows, digest(data)


def state_hash(entries, tokens):
    identities = [f"{x['globalLayerIndex']}|{x['component']}|{x['shape']}|{x['dtype']}|{x['byteCount']}|{x['sha256']}" for x in entries]
    return digest(('cbv2-owned-state-v1\ntokens=' + str(tokens) + '\n' + '\n'.join(identities)).encode())


def check_state(state, tokens, expected):
    require(type(state) is dict and set(state) == {'committedTokens', 'entries', 'logicalByteCount', 'fingerprint'},
        'State record fields differ')
    exact(state['committedTokens'], tokens, 'state frontier')
    entries = state['entries']; base = base_helper()
    require(type(entries) is list and len(entries) == 72, 'Complete 32-layer state requires 72 components')
    for entry in entries:
        require(type(entry) is dict and set(entry) == {'globalLayerIndex', 'component', 'shape', 'dtype', 'byteCount', 'sha256'},
            'State entry fields differ')
        base.sha_string(entry['sha256'])
    geometry = [{key: value for key, value in entry.items() if key != 'sha256'} for entry in entries]
    exact(geometry, base.state_geometry(32, 'bfloat16', tokens, expected), 'independent state geometry/order')
    for entry in entries: base.parameter_bytes(entry, 'dtype')
    exact(state['logicalByteCount'], sum(entry['byteCount'] for entry in entries), 'complete state byte accounting')
    exact(state['fingerprint'], state_hash(entries, tokens), 'state fingerprint')
    return state['fingerprint']


def request_identity(recorded):
    require(type(recorded) is dict and set(recorded) == {'request', 'vocabularySize', 'promptTokenIDs', 'teacherTokenIDs', 'steps', 'fingerprint'},
        'Recorded request fields differ')
    spec = recorded['request']
    require(type(spec) is dict and set(spec) == {'requestID', 'promptCount', 'chunkSize', 'outputCount'}, 'Request spec fields differ')
    exact({key: spec[key] for key in ['promptCount', 'chunkSize', 'outputCount']},
        dict(promptCount=65, chunkSize=32, outputCount=1), 'fixed prefill request')
    require(type(spec['requestID']) is str, 'Request UUID must be text')
    request_id = uuid.UUID(spec['requestID'])
    require(spec['requestID'].lower() == str(request_id), 'Invalid request UUID representation')
    exact(recorded['vocabularySize'], 248320, 'request vocabulary')
    exact(recorded['teacherTokenIDs'], [], 'one-output request teachers')
    prompt = recorded['promptTokenIDs']
    require(type(prompt) is list and len(prompt) == 65 and all(type(t) is int and 0 <= t < 248320 for t in prompt),
        'Invalid prompt tokens')
    require(digest(canonical(prompt)) == PROMPT_CANONICAL_SHA, 'Registered natural65 prompt changed')
    simple = digest(f'qwen-stage-request-v1|{request_id}|65|32|1'.encode())
    fingerprint = digest(('qwen-layer-stage-recorded-request-v1\n' + simple + '\nvocabulary=248320\nprompt='
        + ','.join(map(str, prompt)) + '\nteacher=').encode())
    exact(recorded['fingerprint'], fingerprint, 'recorded request fingerprint')
    steps = []
    for index, tokens in enumerate(FRONTIERS):
        offset = 0 if index == 0 else FRONTIERS[index - 1]
        frame = dict(sequence=index, phase='prefill', tokenOffset=offset, tokenCount=tokens-offset, finalPromptChunk=index == 2)
        steps.append(dict(frame=frame, tokenIDs=prompt[offset:tokens]))
    exact(recorded['steps'], steps, 'fixed prefill frame/token timeline')
    return simple, fingerprint


def session_identity(load, rank, simple):
    return dict(stageIndex=rank, requestFingerprint=simple, artifactAggregateSHA256=load['verifiedAggregateSHA256'],
        storageCommitmentSHA256=load['storageCommitmentSHA256'], bf16ConversionEnabled=load['bf16ConversionEnabled'],
        sourceConfigurationSHA256=load['sourceConfigurationSHA256'], constructionConfigurationSHA256=load['constructionConfigurationSHA256'],
        planFingerprint=load['planSHA256'], stageFingerprint=load['stagePlanSHA256'], activationDType=load['embeddingActivationDType'])


def check_baseline(checkpoint, expected, old_checkpoint=None):
    require(type(checkpoint) is dict and set(checkpoint) == {'kind', 'baselineModelReleasedBeforeStageLoading', 'baseline', 'memory'},
        'Baseline checkpoint fields differ')
    exact(checkpoint['kind'], 'qwen_layer_stage_baseline_checkpoint', 'baseline checkpoint kind')
    exact(checkpoint['baselineModelReleasedBeforeStageLoading'], True, 'baseline model release assertion')
    baseline = checkpoint['baseline']
    require(type(baseline) is dict and set(baseline) == {'kind', 'correctnessOnly', 'throughputMeasurementValid',
        'request', 'source', 'frames', 'fingerprint', 'allRequestStateRetired'}, 'Baseline evidence fields differ')
    exact(baseline['kind'], 'qwen_layer_stage_recorded_baseline', 'baseline kind')
    base = base_helper()
    base.flags(baseline, correctnessOnly=True, throughputMeasurementValid=False, allRequestStateRetired=True)
    source = baseline['source']
    exact(source, dict(artifactAggregateSHA256=expected['artifactAggregateSHA256ClaimedByPinnedManifest'],
        sourceConfigurationSHA256=expected['configurationSHA256'], sourceParameterLayoutSHA256=expected['sourceParameterLayoutSHA256'],
        planSHA256='2b5aa52cab49c12cfa44f2348326f956127d2ca15b1c55b5632f447901e56293', bf16ConversionEnabled=True,
        embeddingActivationDType='bfloat16', sourceModelTensorBytes=expected['sourceModelTensorBytes'], layerCount=32,
        vocabularySize=248320), 'pinned real9B source identity')
    simple, request_hash = request_identity(baseline['request'])
    require(type(baseline['frames']) is list and len(baseline['frames']) == 3, 'Baseline must capture three prompt frontiers')
    frame_hashes, state_hashes, native_logits = [], [], None
    for index, (frame, step, tokens) in enumerate(zip(baseline['frames'], baseline['request']['steps'], FRONTIERS)):
        keys = {'frame', 'committedTokens', 'outputKind', 'outputShape', 'outputDType', 'state'} | ({'logits'} if index == 2 else set())
        require(type(frame) is dict and set(frame) == keys, 'Baseline frame fields differ')
        exact(frame['frame'], step['frame'], 'baseline frame')
        exact(frame['committedTokens'], tokens, 'baseline committed tokens')
        kind, shape = ('logits', [1, 248320]) if index == 2 else ('evaluation_handle', [1, 1])
        exact(frame['outputKind'], kind, 'baseline output kind'); exact(frame['outputShape'], shape, 'baseline output shape')
        exact(frame['outputDType'], 'bfloat16', 'baseline output dtype')
        state_hashes.append(check_state(frame['state'], tokens, expected))
        if index == 2:
            native_logits = base.logical_bytes(frame['logits'], 248320, 'bfloat16')
            logit_hash = digest(native_logits)
        else: logit_hash = 'no-logits'
        f = step['frame']
        frame_hashes.append(digest(('qwen-recorded-frame-v1\n'
            + f"{index}|prefill|{f['tokenOffset']}|{f['tokenCount']}|{str(f['finalPromptChunk']).lower()}\n"
            + f'tokens={tokens}\n{kind}|{shape}|bfloat16\n{state_hashes[-1]}\n{logit_hash}').encode()))
    baseline_hash = digest(('qwen-layer-stage-baseline-v1\n' + request_hash + '\n' + digest(canonical(source))
        + '\n' + '\n'.join(frame_hashes)).encode())
    exact(baseline['fingerprint'], baseline_hash, 'baseline complete fingerprint')
    if old_checkpoint is not None:
        require(digest(canonical(old_checkpoint)) == OLD_CHECKPOINT_SHA, 'Separately frozen old checkpoint changed')
        old = old_checkpoint['baseline']
        require(uuid.UUID(old['request']['request']['requestID']) != uuid.UUID(baseline['request']['request']['requestID']),
            'New control reused old baseline request UUID')
        exact(source, old['source'], 'old/current source')
        exact(baseline['request']['promptTokenIDs'], old['request']['promptTokenIDs'], 'old/current prompt')
        for current, previous in zip(baseline['frames'], old['frames'][:3]):
            exact({k: v for k, v in current.items() if k != 'logits'}, {k: v for k, v in previous.items() if k != 'logits'},
                'old/current full prefill frame metadata/state')
        old_native = base.logical_bytes(old['frames'][2]['logits'], 248320, 'bfloat16')
        require(native_logits == old_native, 'Old/current independently reconstructed native vocabulary bytes differ')
    return dict(simple=simple, requestSHA256=request_hash, baselineSHA256=baseline_hash,
        stateSHA256=state_hashes, nativeLogits=native_logits)


def check_memory(checkpoint, report):
    phases = ['before_baseline_load', 'baseline_released_cache_cleared', 'both_stages_loaded',
        'stage_requests_retired', 'stage_models_released_cache_cleared']
    memory = report['memory']
    require(type(memory) is list and len(memory) == 5, 'Memory phase coverage differs')
    previous_peak = 0
    for observation, phase in zip(memory, phases):
        require(type(observation) is dict and set(observation) == {'phase', 'activeMLXBytes', 'cachedMLXBytes', 'peakMLXBytesSinceProcessStart'},
            'Memory observation fields differ')
        exact(observation['phase'], phase, 'memory phase')
        for key in ['activeMLXBytes', 'cachedMLXBytes', 'peakMLXBytesSinceProcessStart']: base_helper().integer(observation[key])
        require(observation['peakMLXBytesSinceProcessStart'] >= max(previous_peak, observation['activeMLXBytes']), 'MLX cumulative peak differs')
        previous_peak = observation['peakMLXBytesSinceProcessStart']
    exact(checkpoint['memory'], memory[:2], 'baseline memory history')
    require(memory[1]['cachedMLXBytes'] == memory[-1]['cachedMLXBytes'] == 0, 'Released-model MLX caches not cleared')
    conv, ssm, kv, boundary = 4 * 3 * 8192, 4 * 32 * 128 * 128, 2 * 4 * 66 * 4 * 256, 32 * 4096 * 4
    conservative = 3 * 24 * (conv + ssm) + 8 * (kv + 4) + max(conv, ssm, kv // 2) + 2 * boundary
    exact(report['conservativeStateAndBoundaryBytes'], conservative, '65/32/1 conservative tensor admission')


def check_prefill_pair(checkpoint, report, expected, old_checkpoint=None, old_stage_loads=None):
    """Validate records. Optional old evidence must match its frozen CPU pins."""
    require(digest(canonical(expected)) == EXPECTED_CANONICAL_SHA, 'Independent real9B expected metadata changed')
    require(type(report) is dict and set(report) == {'kind', 'schemaVersion', 'correctnessOnly', 'throughputMeasurementValid',
        'baselineModelReleasedBeforeStageLoading', 'stageModelsReleasedAfterComparison',
        'conservativeStateAndBoundaryBytes', 'stageLoads', 'comparison', 'memory'}, 'Prefill report fields differ')
    exact(report['kind'], 'qwen_layer_stage_prefill_report', 'prefill report kind')
    exact(report['schemaVersion'], 1, 'prefill report schema')
    base = base_helper()
    base.flags(report, correctnessOnly=True, throughputMeasurementValid=False,
        baselineModelReleasedBeforeStageLoading=True, stageModelsReleasedAfterComparison=True)
    control = check_baseline(checkpoint, expected, old_checkpoint)
    baseline = checkpoint['baseline']; source = baseline['source']; request = baseline['request']
    require(digest(canonical(report['stageLoads'])) == OLD_STAGE_LOADS_SHA, 'Complete fixed real9B load receipts changed')
    inventory = base.stage_inventory(source, report['stageLoads'], expected)
    if old_stage_loads is not None:
        require(digest(canonical(old_stage_loads)) == OLD_STAGE_LOADS_SHA, 'Old stage-load evidence changed')
        exact(report['stageLoads'], old_stage_loads, 'old/current complete source loads')
    comparison = report['comparison']
    comparison_keys = {'kind', 'correctnessOnly', 'throughputMeasurementValid', 'sequentialOneProcessOnly',
        'nativeBoundaryBytesCopied', 'baselineEvidenceSHA256', 'requestSHA256', 'source', 'stageStorageCommitmentSHA256',
        'stageIdentities', 'frames', 'completedFrames', 'committedTokens', 'token', 'tokenComparison', 'finalLogits',
        'finalState', 'stateMetadataAndDigestsExact', 'nativeLogitBytesExact', 'captureCounts', 'allRequestStateRetired'}
    require(type(comparison) is dict and set(comparison) == comparison_keys, 'Prefill comparison exact fields differ')
    exact(comparison['kind'], 'qwen_layer_stage_prefill_compute_comparison', 'prefill comparison kind')
    base.flags(comparison, correctnessOnly=True, throughputMeasurementValid=False, sequentialOneProcessOnly=True,
        nativeBoundaryBytesCopied=True, stateMetadataAndDigestsExact=True, nativeLogitBytesExact=True, allRequestStateRetired=True)
    exact(comparison['source'], source, 'baseline/candidate source')
    exact(comparison['requestSHA256'], control['requestSHA256'], 'candidate request fingerprint')
    exact(comparison['baselineEvidenceSHA256'], control['baselineSHA256'], 'candidate baseline binding')
    exact(comparison['stageStorageCommitmentSHA256'], report['stageLoads'][0]['storageCommitmentSHA256'], 'candidate storage binding')
    identities = [session_identity(load, rank, control['simple']) for rank, load in enumerate(report['stageLoads'])]
    exact(comparison['stageIdentities'], identities, 'stage identities')
    exact(comparison['completedFrames'], 3, 'completed prompt frames'); exact(comparison['committedTokens'], 65, 'final prompt frontier')
    expected_frames = []
    for index, step in enumerate(request['steps']):
        commits = []
        for rank in range(2):
            output_kind = 'hidden' if rank == 0 else ('logits' if index == 2 else 'evaluation_handle')
            output_shape = [1, step['frame']['tokenCount'], 4096] if rank == 0 else ([1, 248320] if index == 2 else [1, 1])
            commits.append(dict(identity=identities[rank], recordedRequestFingerprint=control['requestSHA256'],
                frame=step['frame'], committedTokens=FRONTIERS[index], outputKind=output_kind,
                outputShape=output_shape, outputDType='bfloat16'))
        expected_frames.append(dict(frame=step['frame'], committedTokens=FRONTIERS[index], stageCommits=commits))
    exact(comparison['frames'], expected_frames, 'complete small per-stage commit metadata')
    check_state(comparison['finalState'], 65, expected)
    exact(comparison['finalState'], baseline['frames'][2]['state'], 'final candidate/baseline state metadata and digests')
    logit_hash = digest(control['nativeLogits']); final_frame = request['steps'][2]['frame']
    final_metadata = dict(kind='qwen_layer_stage_prefill_final_logits', identity=identities[1],
        recordedRequestFingerprint=control['requestSHA256'], frame=final_frame, committedTokens=65,
        vocabularySize=248320, shape=[1, 248320], dtype='bfloat16', byteCount=496640, logicalBytesSHA256=logit_hash)
    exact(comparison['finalLogits'], final_metadata, 'candidate final native logit metadata/SHA')
    values = baseline['frames'][2]['logits']['values']
    maximum = max(values); token = next(index for index, value in enumerate(values) if value == maximum)
    tie_count = sum(value == maximum for value in values)
    exact(comparison['token'], dict(kind='qwen_layer_stage_prefill_local_token', identity=identities[1],
        recordedRequestFingerprint=control['requestSHA256'], frame=final_frame, committedTokens=65, vocabularySize=248320,
        outputOrdinal=0, selectionPolicy='mlx_argmax_all_axes_with_finite_guard_v1', tokenID=token,
        logitsShape=[1, 248320], logitsDType='bfloat16', selectionDType='uint32', allLogitsFinite=True), 'native token receipt')
    exact(comparison['tokenComparison'], dict(policy='finite_maximum_lowest_vocabulary_index_v1', baselineTokenID=token,
        selectedTokenID=token, maximumLogit=maximum, maximumTieCount=tie_count, tokenExact=True), 'independent CPU argmax comparison')
    exact(comparison['captureCounts'], dict(perFrameStateSnapshots=0, perFrameLogitCaptures=0, finalStateSnapshots=2,
        finalLogitCaptures=1, nativeTokenSelections=1, nativeBoundaryCopies=3), 'explicit candidate observation-call counts')
    check_memory(checkpoint, report)
    return dict(status='passed', scope='registered_real9b_natural65_chunk32_output1_no_teacher',
        requestSHA256=control['requestSHA256'], baselineEvidenceSHA256=control['baselineSHA256'],
        vocabularySize=248320, dtype='bfloat16', committedTokens=65, completedFramesPerStage=[3, 3],
        baselineStateFrontiers=list(FRONTIERS), baselineStateComponentsPerFrame=72,
        baselineStateSHA256=control['stateSHA256'], candidateFinalStateComponents=72,
        candidateFinalStateBytes=comparison['finalState']['logicalByteCount'], candidateFinalStateSHA256=comparison['finalState']['fingerprint'],
        reconstructedCurrentBaselineNativeRows=1, reconstructedOldBaselineNativeRows=1 if old_checkpoint is not None else 0,
        reconstructedCandidateNativeRows=0, nativeLogitValuesPerReferenceRow=248320, nativeLogitBytesPerRow=496640,
        finalNativeLogitsSHA256=logit_hash, candidateFinalMetadataAndSHAExact=True, candidateRawByteEqualityAssertedByNative=True,
        argmaxTokenID=token, maximumLogit=maximum, maximumTieCount=tie_count,
        explicitCandidateCaptureCounts=comparison['captureCounts'], inventory=inventory,
        oldFourOutputControlFirstThreePrefillFramesExact=old_checkpoint is not None,
        allRequestStateRetiredNativeAssertion=True, modelReleaseNativeAssertions=True,
        throughputQualified=False, simultaneousGPUExecutionQualified=False, physicalTwoMachineExecution=False,
        limitations=[
            'The current baseline exports the full finite BF16 vocabulary row; CPU reconstructs its exact logical bytes, including signed zeros.',
            'The candidate exports only final logit metadata and SHA. Its private full-byte equality is asserted by the source-bound native comparison and cannot be independently reconstructed from this JSON.',
            'State comparisons use all 72 exported component metadata/SHA entries; no raw candidate or baseline state arrays are exported.',
            'Capture counts describe explicit calls in the comparison helper; unchanged session ownership checks, boundary hashes/copies and root evaluations remain.',
            'Commit, retirement and weak-model-release flags are native assertions. This one-process correctness control contains no timer, speedup proof or physical network transfer.'])


def validate(path, old_baseline_path, expected):
    """Read saved JSON only. Caller separately binds executable/source/artifacts."""
    rows, current_sha = read_rows(path)
    old_rows, old_sha = read_rows(old_baseline_path)
    require(old_sha == BASELINE_STDOUT_SHA, 'Frozen old baseline stdout changed')
    if isinstance(expected, (str, Path)):
        with Path(expected).open('rb') as stream: data = stream.read(4 * 1024**2 + 1)
        require(len(data) <= 4 * 1024**2, 'Expected inventory JSON exceeds bound')
        expected = base_helper().parse_json(data.decode('utf-8'))
    result = check_prefill_pair(rows[0], rows[1], expected, old_rows[0], old_rows[1]['stageLoads'])
    result.update(currentStdoutSHA256=current_sha, oldBaselineStdoutSHA256=old_sha,
        expectedMetadataCanonicalSHA256=EXPECTED_CANONICAL_SHA, helperSHA256=digest(Path(__file__).read_bytes()))
    return result


if __name__ == '__main__':
    require(len(sys.argv) == 4, 'Usage: qwen_layer_stage_prefill_audit.py CURRENT_JSONL OLD_JSONL EXPECTED_JSON')
    print(json.dumps(validate(*sys.argv[1:]), indent=2, sort_keys=True, allow_nan=False))
