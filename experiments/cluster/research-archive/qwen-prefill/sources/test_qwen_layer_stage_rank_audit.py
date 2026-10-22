"""CPU regressions using copied persisted records; never runs a model or rank."""
import copy
import importlib.util
import json
import math
from pathlib import Path
import struct
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('rank_audit', ROOT / 'qwen_layer_stage_rank_audit.py')
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)
RUN = ROOT / 'runs/qwen-layer-stage-ranks-20260914'
OLD = ROOT / 'runs/qwen-layer-stage-real9b-20260913/native/stdout.txt'


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


class RankAuditTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.epoch = json.loads((RUN / 'receipt.json').read_text())['epoch']
        cls.old, _ = audit.read_rows(OLD)
        cls.rows = [audit.read_rows(RUN / f'rank-{rank}/stdout.jsonl')[0] for rank in range(2)]
        cls.expected = json.loads((ROOT / 'qwen-layer-stage-real9b-expected-20260913.json').read_text())

    def check(self, rows, **kwargs):
        return audit.validate_reports(rows, self.old, self.epoch, self.expected, **kwargs)

    def test_actual_positive(self):
        result = audit.validate([RUN / f'rank-{rank}/stdout.jsonl' for rank in range(2)], OLD, self.epoch, self.expected)
        self.assertEqual((result['frameCount'], result['combinedStateEntriesChecked'], result['nativeLogitValuesPerSide']),
            (6, 432, 993280))

    def test_signed_zero_native_bytes(self):
        record = dict(shape=[1, 2], dtype='bfloat16', byteCount=4,
            logicalBytesSHA256=audit.digest(b'\x00\x80\x00\x00'), values=[-0.0, 0.0])
        self.assertEqual(audit.base_helper().logical_bytes(record, 2, 'bfloat16'), b'\x00\x80\x00\x00')
        record['values'][0] = 0.0
        with self.assertRaisesRegex(ValueError, 'SHA differs'):
            audit.base_helper().logical_bytes(record, 2, 'bfloat16')

    def test_common_boundary_replacement_is_documented_limit(self):
        # No persisted raw cutpoint or prior cutpoint means this cannot be
        # independently rejected when both records and headers are rewritten.
        rows = copy.deepcopy(self.rows)
        for rank in range(2): rows[rank][1]['frames'][0]['capture']['boundaryPayloadSHA256'] = 'a' * 64
        reheader(rows)
        result = self.check(rows)
        self.assertFalse(result['hiddenCutpointComparedToPriorBaseline'])
        self.assertFalse(result['observedBoundaryPayloadBytesAvailable'])


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


def negative(mutation):
    def test(self):
        rows = copy.deepcopy(self.rows)
        mutation(rows)
        with self.assertRaises(ValueError): self.check(rows)
    return test


for name, mutation in MUTATIONS.items():
    setattr(RankAuditTests, 'test_reject_' + name, negative(mutation))


class StrictJSONTests(unittest.TestCase):
    def read(self, data):
        with tempfile.TemporaryDirectory(prefix='rank-audit-json-') as directory:
            path = Path(directory) / 'record.jsonl'; path.write_bytes(data)
            return audit.read_rows(path)

    def test_negative_integer_zero_is_preserved(self):
        rows, _ = self.read(b'{"value":-0}\n{}\n')
        self.assertEqual(math.copysign(1, rows[0]['value']), -1)

    def test_bad_json(self):
        cases = [b'{"x":1,"x":2}\n{}\n', b'{"x":NaN}\n{}\n', b'[]\n{}\n',
            b'{}\n{}\n{}\n', b'{}\n', b'\xff\n{}\n',
            b'{"x":' + b'[' * 17 + b'0' + b']' * 17 + b'}\n{}\n']
        for data in cases:
            with self.subTest(data=data[:50]):
                with self.assertRaises(ValueError): self.read(data)


if __name__ == '__main__': unittest.main()
