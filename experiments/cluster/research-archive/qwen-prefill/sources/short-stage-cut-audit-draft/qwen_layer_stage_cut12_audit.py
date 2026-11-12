"""Prospective registered9B cut12 variant; old recorded numerical algorithm retained."""
import hashlib
import json
import math
import re
import struct
import uuid

WIDTH = {'float16': 2, 'bfloat16': 2, 'float32': 4, 'uint32': 4, 'int32': 4}
FRONTIERS = [32, 64, 65, 66, 67, 68]
EXPECTED_CANONICAL_SHA256 = 'b7e0c1110ff919a8b62f496a597145e0b845758dae6268254cd413f183c9c2fe'
EXPLICIT_RANGES = [(0, 12), (12, 32)]


def require(ok, message):
    if not ok:
        raise ValueError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False, allow_nan=False).encode()


def parse_json(text):
    """Preserve Swift JSONEncoder's integer spelling -0 as floating negative zero."""
    def unique(items):
        out = {}
        for key, value in items:
            require(key not in out, 'Duplicate JSON key')
            out[key] = value
        return out
    return json.loads(text, object_pairs_hook=unique,
        parse_int=lambda value: -0.0 if value == '-0' else int(value),
        parse_constant=lambda _: require(False, 'Nonfinite JSON'))


def integer(value, minimum=0):
    require(type(value) is int and value >= minimum, 'Invalid bounded integer')
    return value


def sha_string(value):
    require(type(value) is str and re.fullmatch('[0-9a-f]{64}', value), 'Invalid SHA256')
    return value


def flags(obj, **expected):
    for key, value in expected.items():
        require(obj.get(key) is value, 'Evidence flag differs: ' + key)


def equal(actual, expected, message):
    require(canonical(actual) == canonical(expected), message)


def logical_bytes(record, vocabulary, dtype):
    require(set(record) == {'shape', 'dtype', 'byteCount', 'logicalBytesSHA256', 'values'}, 'Logit record fields differ')
    equal(record['shape'], [1, vocabulary], 'Incomplete vocabulary row')
    require(record['dtype'] == dtype and dtype in ('float16', 'bfloat16', 'float32'), 'Logit dtype differs')
    require(integer(record['byteCount']) == vocabulary * WIDTH[dtype]
        and isinstance(record['values'], list) and len(record['values']) == vocabulary, 'Logit storage count differs')
    result = bytearray()
    for value in record['values']:
        require(type(value) in (int, float) and math.isfinite(value), 'Nonfinite/bool logit')
        try:
            packed = struct.pack('<f', value)
            floating = struct.unpack('<f', packed)[0]
            require(math.isfinite(floating), 'Float32 logit overflow')
            if dtype == 'float16':
                half = struct.pack('<e', floating)
                require(struct.unpack('<e', half)[0] == floating, 'Value not exactly float16')
                result.extend(half)
            elif dtype == 'bfloat16':
                bits = struct.unpack('<I', packed)[0]
                require(bits & 65535 == 0, 'Value not exactly bfloat16')
                result.extend(struct.pack('<H', bits >> 16))
            else:
                result.extend(packed)
        except (OverflowError, struct.error) as error:
            raise ValueError('Out-of-range native logit value') from error
    require(digest(result) == sha_string(record['logicalBytesSHA256']), 'Native logit bytes SHA differs')
    return bytes(result)


def parameter_bytes(tensor, dtype_key):
    shape, dtype = tensor['shape'], tensor[dtype_key]
    require(isinstance(shape, list) and shape and all(type(v) is int and v > 0 for v in shape)
        and dtype in WIDTH, 'Invalid tensor shape/dtype')
    require(integer(tensor['byteCount']) == math.prod(shape) * WIDTH[dtype], 'Tensor byte count differs')
    return tensor['byteCount']


def layout(tensors, name='localName', dtype='loadedDType'):
    return digest('\n'.join(sorted(f"{x[name]}:{x[dtype]}:{x['shape']}" for x in tensors)).encode())


def stage_inventory(source, loads, expected):
    require(isinstance(loads, list) and len(loads) == 2, 'Expected two stage loads')
    full, summaries, source_names = [], [], set()
    layers, hidden = source['layerCount'], 4096 if expected else 128
    namespace = 'language_model.' if loads[0]['activeTensors'][0]['sourceName'].startswith('language_model.') else ''
    common = loads[0]['storageCommitment']
    for index, receipt in enumerate(loads):
        require(integer(receipt['schemaVersion']) == 1 and integer(receipt['stageIndex']) == index, 'Receipt stage/schema differs')
        for key in ['sourceConfigurationSHA256', 'sourceParameterLayoutSHA256', 'planSHA256', 'sourceModelTensorBytes',
                'bf16ConversionEnabled', 'embeddingActivationDType']:
            equal(receipt[key], source[key], 'Source/loaded-stage identity differs: ' + key)
        require(receipt['verifiedAggregateSHA256'] == source['artifactAggregateSHA256'], 'Artifact identity differs')
        for key in ['constructionConfigurationSHA256', 'stagePlanSHA256', 'sourceTensorManifestSHA256',
                'parameterLayoutSHA256', 'activeParameterLayoutSHA256', 'activeMappingSHA256', 'storageCommitmentSHA256']:
            sha_string(receipt[key])
        for key in ['constructionConfigurationSHA256', 'stagePlanSHA256']:
            equal(receipt[key], expected['stages'][index][key], 'Pinned cut12 stage identity differs: ' + key)
        entries = receipt['activeTensors']
        require(isinstance(entries, list) and len(entries) == len(expected['stages'][index]['activeTensors']), 'Stage tensor count differs')
        equal(entries, sorted(entries, key=lambda x: x['localName']), 'Active inventory order differs')
        local_names = set()
        for tensor in entries:
            require(set(tensor) == {'sourceName', 'localName', 'shape', 'sourceDType', 'loadedDType', 'byteCount'}, 'Active descriptor fields differ')
            name = tensor['sourceName']
            require(isinstance(name, str) and name not in source_names, 'Duplicate global parameter owner')
            source_names.add(name)
            match = re.fullmatch(re.escape(namespace) + r'model\.layers\.(\d+)\.(.+)', name)
            if match:
                layer = int(match[1])
                start, end = EXPLICIT_RANGES[index]
                require(start <= layer < end, 'Wrong explicit cut12 source layer owner')
                local = namespace + f'model.layers.{layer - start}.' + match[2]
            else:
                allowed = ([namespace + 'model.embed_tokens.' + s for s in ['weight', 'scales', 'biases']] if index == 0 else
                    [namespace + 'lm_head.' + s for s in ['weight', 'scales', 'biases']] + [namespace + 'model.norm.weight'])
                require(name in allowed, 'Unknown/nontext parameter owner')
                local = name
            require(tensor['localName'] == local and local not in local_names, 'Local mapping differs/collides')
            local_names.add(local)
            require(tensor['sourceDType'] in ('float16', 'bfloat16', 'float32', 'uint32'), 'Unsupported source dtype')
            loaded = 'bfloat16' if source['bf16ConversionEnabled'] and tensor['sourceDType'] == 'float16' else tensor['sourceDType']
            require(tensor['loadedDType'] == loaded, 'Loaded dtype policy differs')
            parameter_bytes(tensor, 'loadedDType')
            full.append(dict(tensor, localName=name))
        require(digest(canonical(entries)) == receipt['activeMappingSHA256']
            and layout(entries) == receipt['activeParameterLayoutSHA256'], 'Active inventory commitment differs')
        inert_expected = [('model.norm', [hidden], 'parameter-only-replacement', 'Replace before parameter evaluation; stage 0 exports pre-final-norm hidden'),
            ('lm_head', [1, hidden], 'module-replacement', 'Replace before parameter evaluation; stage 0 discards lazy logits')] if index == 0 else [
            ('model.embed_tokens', [1, hidden], 'module-replacement', 'Replace before parameter evaluation; incoming residual bypasses embedding; preserve checkpoint activation dtype')]
        inert = receipt['inertModules']
        require(len(inert) == len(inert_expected), 'Inactive inventory count differs')
        inert_map = {x['path']: x for x in inert}
        require(len(inert_map) == len(inert), 'Duplicate inactive path')
        inert_parameters = []
        for path, shape, kind, responsibility in inert_expected:
            path = namespace + path
            equal(inert_map.get(path), dict(path=path, replacementKind=kind, responsibility=responsibility,
                parameters=[dict(localName=path + '.weight', shape=shape, dtype=source['embeddingActivationDType'],
                    byteCount=math.prod(shape) * WIDTH[source['embeddingActivationDType']])]), 'Inactive metadata differs')
            inert_parameters.extend(inert_map[path]['parameters'])
        require(not local_names.intersection(p['localName'] for p in inert_parameters), 'Active/inert collision')
        require(receipt['loadedTensorBytes'] == sum(x['byteCount'] for x in entries)
            and receipt['largestHostTensorBytes'] == max(x['byteCount'] for x in entries)
            and receipt['inertTensorBytes'] == sum(x['byteCount'] for x in inert_parameters), 'Stage storage accounting differs')
        require(layout(entries + [dict(x, loadedDType=x['dtype']) for x in inert_parameters]) == receipt['parameterLayoutSHA256'],
            'Complete active/inert parameter layout differs')
        equal(receipt['storageCommitment'], common, 'Two stages disagree on common commitment')
        require(digest(canonical(common)) == receipt['storageCommitmentSHA256'], 'Common commitment SHA differs')
        summary = {k: receipt[k] for k in ['stageIndex', 'constructionConfigurationSHA256', 'stagePlanSHA256',
            'activeMappingSHA256', 'activeParameterLayoutSHA256', 'parameterLayoutSHA256', 'loadedTensorBytes', 'inertTensorBytes']}
        summary.update(activeTensorCount=len(entries), inertTensorCount=len(inert_parameters))
        summaries.append(summary)
        if expected:
            oracle = expected['stages'][index]
            for key in ['activeTensors', 'activeMappingSHA256', 'activeParameterLayoutSHA256', 'parameterLayoutSHA256',
                    'loadedTensorBytes', 'largestHostTensorBytes', 'inertTensorBytes']:
                equal(receipt[key], oracle[key], 'Independent real stage expectation differs: ' + key)
            stripped = [{k: v for k, v in m.items() if k != 'responsibility'} for m in inert]
            equal(sorted(stripped, key=lambda x: x['path']), sorted(oracle['inertModules'], key=lambda x: x['path']),
                'Independent real inactive metadata differs')
    require(layout(full) == source['sourceParameterLayoutSHA256']
        and sum(t['byteCount'] for t in full) == source['sourceModelTensorBytes'], 'Full canonical source conservation differs')
    # PreparedQwenCheckpoint counts sanitized retained source names, before
    # composition, not every raw header entry. This pinned converted artifact
    # excludes vision/MTP and has one retained source tensor per canonical name.
    retained_sources = expected['sourceHeaderTensorCount'] - expected['excluded']['count'] if expected else 237
    require(retained_sources == len(full), 'Retained source/canonical inventory differs for the pinned artifact')
    require(common['schemaVersion'] == 1 and common['canonicalTensorCount'] == len(full)
        and common['sourceTensorCount'] == retained_sources
        and common['largestSourceTensorBytes'] == max(t['byteCount'] for t in full), 'Common source accounting differs')
    for key in ['verifiedAggregateSHA256', 'sourceConfigurationSHA256', 'planSHA256', 'sourceTensorManifestSHA256',
            'sourceModelTensorBytes', 'bf16ConversionEnabled']:
        equal(common[key], loads[0][key], 'Common source identity differs: ' + key)
    equal(common['stages'], summaries, 'Common per-stage summary differs')
    if expected:
        equal(sorted(full, key=lambda x: x['sourceName']), expected['fullCanonicalTensors'], 'Independent full canonical inventory differs')
    return dict(canonicalTensors=len(full), activeTensorBytes=[x['loadedTensorBytes'] for x in loads],
        inertTensorBytes=[x['inertTensorBytes'] for x in loads])


def state_geometry(layers, dtype, tokens, expected):
    if expected:
        frame = next((x for x in expected['stateFrames'] if x['committedTokens'] == tokens), None)
        require(frame is not None, 'Independent state frontier missing')
        return [{k: x[k] for k in ['globalLayerIndex', 'component', 'shape', 'dtype', 'byteCount']} for x in frame['entries']]
    out = []
    for layer in range(layers):
        parts = [('kv.keys', [1, 2, tokens, 64], dtype), ('kv.values', [1, 2, tokens, 64], dtype),
            ('kv.position_offsets', [1], 'int32')] if (layer + 1) % 4 == 0 else [
            ('conv', [1, 3, 768], dtype), ('ssm', [1, 2, 128, 128], 'float32')]
        for component, shape, dt in parts:
            out.append(dict(globalLayerIndex=layer, component=component, shape=shape, dtype=dt, byteCount=math.prod(shape) * WIDTH[dt]))
    return sorted(out, key=lambda x: (x['globalLayerIndex'], x['component']))


def check_recorded_pair(checkpoint: dict, report: dict, expected: dict | None = None) -> dict:
    require(isinstance(expected, dict) and digest(canonical(expected)) == EXPECTED_CANONICAL_SHA256,
        'Exact prospectively derived cut12 expectation is required')
    require(checkpoint['kind'] == 'qwen_layer_stage_baseline_checkpoint'
        and report['kind'] == 'qwen_layer_stage_comparison_report', 'Wrong outer record kinds')
    flags(checkpoint, baselineModelReleasedBeforeStageLoading=True)
    flags(report, correctnessOnly=True, throughputMeasurementValid=False,
        baselineModelReleasedBeforeStageLoading=True, stageModelsReleasedAfterComparison=True)
    baseline, comparison = checkpoint['baseline'], report['comparison']
    require(baseline['kind'] == 'qwen_layer_stage_recorded_baseline'
        and comparison['kind'] == 'qwen_layer_stage_recorded_comparison', 'Wrong inner evidence kinds')
    flags(baseline, correctnessOnly=True, throughputMeasurementValid=False, allRequestStateRetired=True)
    flags(comparison, correctnessOnly=True, throughputMeasurementValid=False, sequentialOneProcessOnly=True,
        nativeBoundaryBytesCopied=True, allRequestStateRetired=True)
    source = baseline['source']
    require(set(source) == {'artifactAggregateSHA256', 'sourceConfigurationSHA256', 'sourceParameterLayoutSHA256',
        'planSHA256', 'bf16ConversionEnabled', 'embeddingActivationDType', 'sourceModelTensorBytes', 'layerCount', 'vocabularySize'},
        'Source identity fields differ')
    for key in ['artifactAggregateSHA256', 'sourceConfigurationSHA256', 'sourceParameterLayoutSHA256', 'planSHA256']:
        sha_string(source[key])
    flags(source, bf16ConversionEnabled=True)
    layers, vocab, dtype = source['layerCount'], source['vocabularySize'], source['embeddingActivationDType']
    require(integer(layers) == (32 if expected else 8) and integer(vocab) == (248320 if expected else 512)
        and dtype in ('float16', 'bfloat16', 'float32') and integer(source['sourceModelTensorBytes'], 1), 'Source model geometry differs')
    if expected:
        require(expected['kind'] == 'qwen_layer_stage_real9b_cut12_expected' and dtype == 'bfloat16', 'Wrong real expected oracle')
        for key, expected_key in [('artifactAggregateSHA256', 'artifactAggregateSHA256ClaimedByPinnedManifest'),
                ('sourceConfigurationSHA256', 'configurationSHA256'), ('sourceParameterLayoutSHA256', 'sourceParameterLayoutSHA256'),
                ('sourceModelTensorBytes', 'sourceModelTensorBytes'), ('planSHA256', 'planSHA256')]:
            equal(source[key], expected[expected_key], 'Pinned real source identity differs: ' + key)
    equal(comparison['source'], source, 'Baseline/staged source identity differs')
    inventory = stage_inventory(source, report['stageLoads'], expected)
    require(comparison['stageStorageCommitmentSHA256'] == report['stageLoads'][0]['storageCommitmentSHA256'], 'Comparison storage binding differs')
    recorded = baseline['request']; spec = recorded['request']
    require(set(spec) == {'requestID', 'promptCount', 'chunkSize', 'outputCount'}, 'Request spec fields differ')
    equal({k: spec[k] for k in ['promptCount', 'chunkSize', 'outputCount']},
        dict(promptCount=65, chunkSize=32, outputCount=4), 'Only the fixed 65/32/4 request is qualified')
    request_id = str(uuid.UUID(spec['requestID']))
    require(request_id == spec['requestID'].lower(), 'Invalid request UUID representation')
    request_hash = digest(f'qwen-stage-request-v1|{request_id}|65|32|4'.encode())
    prompt, teacher = recorded['promptTokenIDs'], recorded['teacherTokenIDs']
    require(len(prompt) == 65 and len(teacher) == 3 and recorded['vocabularySize'] == vocab
        and all(type(t) is int and 0 <= t < vocab for t in prompt + teacher), 'Actual token history differs')
    if expected is None:
        equal(prompt, [3 + ((i * 17 + 7) % 509) for i in range(65)], 'Tiny fixture prompt differs')
        equal(teacher, [12, 25, 38], 'Tiny fixture teacher history differs')
    recorded_hash = digest(('qwen-layer-stage-recorded-request-v1\n' + request_hash + f'\nvocabulary={vocab}\nprompt='
        + ','.join(map(str, prompt)) + '\nteacher=' + ','.join(map(str, teacher))).encode())
    require(recorded['fingerprint'] == recorded_hash == comparison['requestSHA256'], 'Recorded request fingerprint differs')
    require(len(recorded['steps']) == len(baseline['frames']) == len(comparison['frames']) == 6, 'Request frame coverage differs')
    frame_hashes, state_sizes, logit_hashes = [], [], []
    for index, tokens in enumerate(FRONTIERS):
        offset = 0 if index == 0 else FRONTIERS[index - 1]
        frame = dict(sequence=index, phase='prefill' if index < 3 else 'decode', tokenOffset=offset,
            tokenCount=tokens - offset, finalPromptChunk=index == 2)
        token_ids = prompt[offset:tokens] if index < 3 else [teacher[index - 3]]
        equal(recorded['steps'][index], dict(frame=frame, tokenIDs=token_ids), 'Actual frame/token timeline differs')
        original, candidate = baseline['frames'][index], comparison['frames'][index]
        equal(original['frame'], frame, 'Baseline frame differs'); equal(candidate['frame'], frame, 'Candidate frame differs')
        require(original['committedTokens'] == candidate['committedTokens'] == tokens, 'Committed frontier differs')
        expects_logits = index >= 2
        kind, shape = ('logits', [1, vocab]) if expects_logits else ('evaluation_handle', [1, 1])
        require(original['outputKind'] == kind and original['outputDType'] == dtype, 'Output role/dtype differs')
        equal(original['outputShape'], shape, 'Output shape differs')
        state = original['state']; entries = state['entries']
        require(state['committedTokens'] == tokens and len(entries) == (72 if expected else 18), 'State frontier/count differs')
        identities = []
        for entry in entries:
            require(set(entry) == {'globalLayerIndex', 'component', 'shape', 'dtype', 'byteCount', 'sha256'}, 'State entry fields differ')
            integer(entry['globalLayerIndex']); parameter_bytes(entry, 'dtype'); sha_string(entry['sha256'])
            identities.append(f"{entry['globalLayerIndex']}|{entry['component']}|{entry['shape']}|{entry['dtype']}|{entry['byteCount']}|{entry['sha256']}")
        stripped = [{k: v for k, v in e.items() if k != 'sha256'} for e in entries]
        equal(stripped, state_geometry(layers, dtype, tokens, expected), 'Independent state component geometry/order differs')
        state_hash = digest(('cbv2-owned-state-v1\ntokens=' + str(tokens) + '\n' + '\n'.join(identities)).encode())
        require(state['fingerprint'] == state_hash == candidate['globalStateSHA256']
            and state['logicalByteCount'] == sum(e['byteCount'] for e in entries) == candidate['logicalStateBytesPerSide']
            and candidate['stateEntriesCompared'] == len(entries), 'Complete state commitment/accounting differs')
        flags(candidate, stateMetadataAndDigestsExact=True)
        state_sizes.append(state['logicalByteCount'])
        if expects_logits:
            left = logical_bytes(original['logits'], vocab, dtype)
            right = logical_bytes(candidate['logits'], vocab, dtype)
            require(left == right, 'Baseline/staged native logit bytes differ')
            flags(candidate, nativeLogitBytesExact=True)
            logits_hash = digest(left); logit_hashes.append(logits_hash)
        else:
            require(original.get('logits') is None and candidate.get('logits') is None
                and candidate.get('nativeLogitBytesExact') is None, 'Intermediate evaluation frame claims logits')
            logits_hash = 'no-logits'
        frame_hashes.append(digest(('qwen-recorded-frame-v1\n'
            + f"{index}|{frame['phase']}|{offset}|{tokens-offset}|{str(frame['finalPromptChunk']).lower()}\n"
            + f'tokens={tokens}\n{kind}|{shape}|{dtype}\n{state_hash}\n{logits_hash}').encode()))
    baseline_hash = digest(('qwen-layer-stage-baseline-v1\n' + recorded_hash + '\n' + digest(canonical(source))
        + '\n' + '\n'.join(frame_hashes)).encode())
    require(baseline['fingerprint'] == baseline_hash == comparison['baselineEvidenceSHA256'], 'Complete baseline fingerprint differs')
    phases = ['before_baseline_load', 'baseline_released_cache_cleared', 'both_stages_loaded',
        'stage_requests_retired', 'stage_models_released_cache_cleared']
    equal([x['phase'] for x in report['memory']], phases, 'Memory observation phase coverage differs')
    equal(checkpoint['memory'], report['memory'][:2], 'Baseline memory observations changed')
    for observation in report['memory']:
        require(set(observation) == {'phase', 'activeMLXBytes', 'cachedMLXBytes', 'peakMLXBytesSinceProcessStart'}, 'Memory observation fields differ')
        for key in ['activeMLXBytes', 'cachedMLXBytes', 'peakMLXBytesSinceProcessStart']:
            integer(observation[key])
        require(observation['peakMLXBytesSinceProcessStart'] >= observation['activeMLXBytes'], 'Observed peak below active memory')
    conv, ssm = (4 * 3 * 8192, 4 * 32 * 128 * 128) if expected else (4 * 3 * 768, 4 * 2 * 128 * 128)
    kv = 2 * 4 * 69 * (4 * 256 if expected else 2 * 64)
    boundary = 32 * (4096 if expected else 128) * 4
    conservative = 3 * (layers - layers // 4) * (conv + ssm) + (layers // 4) * (kv + 4) + max(conv, ssm, kv // 2) + 2 * boundary
    require(report['conservativeStateAndBoundaryBytes'] == conservative, 'Conservative state/boundary estimate differs')
    return dict(status='passed', explicitStageCut=12, stageLayerRanges=[[0,12],[12,32]],
        planSHA256=expected['planSHA256'], vocabularySize=vocab, layerCount=layers, dtype=dtype, frames=6,
        stateEntriesPerFrame=72 if expected else 18, stateBytesPerFrame=state_sizes,
        independentlyVerifiedNativeLogitPairs=4, independentlyVerifiedRawLogitRows=8,
        nativeLogitBytesExact=True, logitLogicalBytesSHA256=logit_hashes,
        recordedRequestSHA256=recorded_hash, baselineEvidenceSHA256=baseline_hash,
        inventory=inventory, realExpectedMetadataChecked=expected is not None,
        stateEvidence='Native per-entry metadata/SHA equality; CPU rederived baseline entry geometry and aggregate fingerprints.',
        pairedRawStateBytesAvailable=False, throughputQualified=False, physicalTwoMachineExecution=False)
