"""Established malicious-record mutations; no real rank records read."""
import struct
import audit_rank_cut12
audit = audit_rank_cut12.core()

def native_sha(logits):
    return audit.digest(b''.join(struct.pack('<H', struct.unpack('<I', struct.pack('<f', v))[0] >> 16)
        for v in logits['values']))

def request_sha(request):
    simple = audit.digest(('qwen-stage-request-v1|' + request['request']['requestID'].lower() + '|65|32|4').encode())
    request['fingerprint'] = audit.digest(('qwen-layer-stage-recorded-request-v1\n' + simple
        + '\nvocabulary=248320\nprompt=' + ','.join(map(str, request['promptTokenIDs']))
        + '\nteacher=' + ','.join(map(str, request['teacherTokenIDs']))).encode())
    return simple

def reheader(rows):
    simple = request_sha(rows[0][1]['request'])
    for rank in range(2):
        request_sha(rows[rank][1]['request'])
        for index, completion in enumerate(rows[rank][1]['frames']):
            completion['headerSHA256'] = audit.digest(audit.header_bytes(rows[0][1]['sourceLoad'], simple,
                rows[rank][1]['request']['steps'][index], completion['capture']['boundaryPayloadSHA256']))

def set_path(path, value):
    def mutate(rows):
        target = rows
        for key in path[:-1]: target = target[key]
        target[path[-1]] = value
    return mutate

def coherent_tokens(rows):
    for rank in range(2):
        request = rows[rank][1]['request']
        request['promptTokenIDs'][0] += 1
        request['steps'][0]['tokenIDs'][0] += 1
    reheader(rows)

def coherent_teacher(rows):
    for rank in range(2):
        request = rows[rank][1]['request']
        request['teacherTokenIDs'][0] += 1
        request['steps'][3]['tokenIDs'][0] += 1
    reheader(rows)

def coherent_source(rows):
    original = rows[0][1]['sourceLoad']['sourceConfigurationSHA256']
    def replace(value):
        if isinstance(value, dict): return {k: replace(v) for k, v in value.items()}
        if isinstance(value, list): return [replace(v) for v in value]
        return 'a' * 64 if value == original else value
    rows[:] = replace(rows)
    for rank in range(2):
        load = rows[rank][1]['sourceLoad']
        load['storageCommitmentSHA256'] = audit.digest(audit.canonical(load['storageCommitment']))
        for completion in rows[rank][1]['frames']:
            completion['capture']['identity']['storageCommitmentSHA256'] = load['storageCommitmentSHA256']
    reheader(rows)

def coherent_state(rows):
    capture = rows[0][1]['frames'][0]['capture']
    capture['stateEntries'][0]['sha256'] = 'a' * 64
    capture['stageStateSHA256'] = audit.state_hash(capture['stateEntries'], capture['committedTokens'])

def coherent_logits(rows):
    logits = rows[1][1]['frames'][2]['capture']['logits']
    logits['values'][0] = 1.0 if logits['values'][0] != 1.0 else 2.0
    logits['logicalBytesSHA256'] = native_sha(logits)

MUTATIONS = {
    'both_tokens_with_recomputed_fingerprints': coherent_tokens,
    'both_teacher_with_recomputed_fingerprints': coherent_teacher,
    'both_source_identity_with_recomputed_commitments': coherent_source,
    'state_digest_with_recomputed_stage_fingerprint': coherent_state,
    'logit_value_with_recomputed_native_digest': coherent_logits,
    'rank_identity': set_path([1, 0, 'rank'], 0),
    'epoch': set_path([0, 0, 'epoch'], '0' * 32),
    'request_uuid': set_path([1, 1, 'request', 'request', 'requestID'], '00000000-0000-0000-0000-000000000000'),
    'request_counter': set_path([0, 1, 'request', 'request', 'promptCount'], 64),
    'request_simple_fingerprint': set_path([0, 1, 'frames', 0, 'capture', 'identity', 'requestFingerprint'], '0' * 64),
    'committed_frontier': set_path([0, 1, 'frames', 0, 'capture', 'committedTokens'], 31),
    'sequence_counter': set_path([1, 1, 'frames', 1, 'capture', 'frame', 'sequence'], 0),
    'token_offset': set_path([1, 1, 'frames', 1, 'capture', 'frame', 'tokenOffset'], 31),
    'native_policy': set_path([0, 1, 'sourceLoad', 'bf16ConversionEnabled'], False),
    'source_local_mapping': set_path([1, 1, 'sourceLoad', 'activeTensors', 0, 'localName'], 'changed.weight'),
    'retained_source_count': set_path([0, 1, 'sourceLoad', 'storageCommitment', 'sourceTensorCount'], 1291),
    'loaded_source_bytes': set_path([0, 1, 'sourceLoad', 'loadedTensorBytes'], 0),
    'state_shape': set_path([1, 1, 'frames', 2, 'capture', 'stateEntries', 0, 'shape'], [1]),
    'state_dtype': set_path([0, 1, 'frames', 1, 'capture', 'stateEntries', 0, 'dtype'], 'float32'),
    'state_wrong_owner': set_path([0, 1, 'frames', 0, 'capture', 'stateEntries', 0, 'globalLayerIndex'], 16),
    'boundary_cross_rank_digest': set_path([1, 1, 'frames', 0, 'capture', 'boundaryPayloadSHA256'], 'b' * 64),
    'boundary_shape': set_path([0, 1, 'frames', 0, 'capture', 'boundaryShape'], [1, 32, 2048]),
    'canonical_header': set_path([1, 1, 'frames', 2, 'headerSHA256'], 'a' * 64),
    'ack_phase': set_path([1, 1, 'frames', 0, 'completedTransportPhase'], 'consumed_ack_received_and_validated'),
    'retirement': set_path([0, 1, 'allRequestStateRetired'], False),
    'release': set_path([1, 1, 'modelReleased'], False),
    'physical_scope': set_path([0, 1, 'physicalTransferQualified'], True),
    'memory_boolean': set_path([0, 1, 'memory', 0, 'activeMLXBytes'], True),
    'memory_peak': set_path([1, 1, 'memory', 1, 'peakMLXBytesSinceProcessStart'], 0),
    'cache_not_cleared': set_path([1, 1, 'memory', 3, 'cachedMLXBytes'], 4),
    'logit_truncation': set_path([1, 1, 'frames', 2, 'capture', 'logits', 'values'], [0]),
    'logit_boolean': set_path([1, 1, 'frames', 2, 'capture', 'logits', 'values', 0], True),
}
