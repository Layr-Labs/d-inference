"""CPU-only malformed/tampered P2P transcript tests; no native output input."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

HELPER = Path('/Users/developer/DarkbloomDev/cluster-research/stage-p2p-cpu-audit-draft.py')
HELPER_SHA = '14b25ddc6e6e3165e3f47efa0f4f10e6eab5a1ef81930bbd15e49babdc577b1d'
assert hashlib.sha256(HELPER.read_bytes()).hexdigest() == HELPER_SHA
spec = importlib.util.spec_from_file_location('p2p_audit', HELPER)
audit = importlib.util.module_from_spec(spec); spec.loader.exec_module(audit)
EPOCH = '0123456789abcdef0123456789abcdef'


class P2PAuditTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='p2p-cpu-fixture-')
        self.addCleanup(self.temp.cleanup)
        self.paths = [Path(self.temp.name) / f'rank{i}.jsonl' for i in range(2)]
        self.records = [audit.expected_records(EPOCH, rank)[0] for rank in range(2)]

    def save(self):
        for path, records in zip(self.paths, self.records):
            path.write_bytes(b'\n'.join(audit.canonical(row) for row in records) + b'\n')

    def rejects(self, message=None):
        self.save()
        with self.assertRaisesRegex(ValueError, message or '.'):
            audit.check_pair(self.paths, EPOCH)

    def test_exact_generated_fixture_transcripts(self):
        self.save()
        result = audit.check_pair(self.paths, EPOCH)
        self.assertEqual(result['residualFramesPerRank'], 54)
        self.assertEqual(result['residualPayloadBytesPerRank'], 6754304)
        self.assertEqual(result['controlPayloadBytesPerRank'], 126)
        self.assertEqual(result['expectedAcknowledgementCount'], 115)
        self.assertFalse(result['observedReceivedPayloadBytesAvailable'])
        self.assertFalse(result['observedAcknowledgementBytesAvailable'])

    def test_ieee_pattern_anchors(self):
        self.assertEqual(audit.fixture_bytes('float32', 8).hex(), '00000000000000800000803f000080bf0000003f00000040000080000000803e')
        self.assertEqual(audit.fixture_bytes('float16', 8).hex(), '00000080003c00bc0038004000040034')
        self.assertEqual(audit.fixture_bytes('bfloat16', 8).hex(), '00000080803f80bf003f00408000803e')
        self.assertEqual(audit.fixture_bytes('uint32', 2).hex(), '00000000ffffffff')
        self.assertEqual(audit.fixture_bytes('float16', 2, shift=1).hex(), '0080003c')

    def test_noncontiguous_control_order(self):
        expected_bytes = bytes.fromhex('000000000000803f0000003f00000080000080bf00000040')
        self.assertEqual(self.records[0][1]['controlCases'][6]['payloadSHA256'], hashlib.sha256(expected_bytes).hexdigest())

    def test_ack_phase_separation(self):
        a = audit.acknowledgement(b'header', 'ready'); b = audit.acknowledgement(b'header', 'consumed')
        self.assertEqual(len(a['values']), 64)
        self.assertTrue(all(v in b'0123456789abcdef' for v in a['values']))
        self.assertNotEqual(a['logicalBytesSHA256'], b['logicalBytesSHA256'])
        self.assertNotEqual(a, audit.acknowledgement(b'other', 'ready'))

    def test_wrong_rank(self):
        self.records[1][0]['rank'] = 0
        self.rejects('rank1')

    def test_wrong_epoch(self):
        self.records[0][1]['epoch'] = 'f' * 32
        self.rejects('epoch')

    def test_wrong_backend(self):
        self.records[1][0]['backend'] = 'jaccl'
        self.rejects('backend')

    def test_missing_control(self):
        self.records[0][1]['controlCases'].pop()
        self.rejects('list length')

    def test_control_shape(self):
        self.records[0][1]['controlCases'][0]['shape'] = [3, 2]
        self.rejects('shape')

    def test_false_noncontiguous_claim(self):
        self.records[0][1]['controlCases'][6]['noncontiguousSender'] = False
        self.rejects('noncontiguousSender')

    def test_bool_instead_of_integer(self):
        self.records[0][0]['rank'] = False
        self.rejects('Wrong JSON type')

    def test_fractional_integer_spelling(self):
        self.records[0][1]['cases'][0]['hiddenSize'] = 128.0
        self.rejects('Wrong JSON type')

    def test_extra_field(self):
        self.records[0][1]['cases'][0]['frames'][0]['unverified'] = True
        self.rejects('exact fields')

    def test_stale_frame(self):
        self.records[0][1]['cases'][0]['frames'][1]['frame']['sequence'] = 0
        self.rejects('sequence')

    def test_wrong_prompt_final_flag(self):
        self.records[0][1]['cases'][0]['frames'][2]['frame']['finalPromptChunk'] = False
        self.rejects('finalPromptChunk')

    def test_same_wrong_payload_both_ranks(self):
        for records in self.records:
            records[1]['cases'][0]['frames'][0]['payloadSHA256'] = '0' * 64
        self.rejects('payloadSHA256')

    def test_coherent_source_identity_tamper_both_ranks(self):
        frame = audit.frame_schedule()[0]
        payload = audit.fixture_bytes('float32', 32 * 128)
        header, _ = audit.wire_header(EPOCH, 'float32-h128', 'float32', 128, frame, payload)
        header['planFingerprint'] = 'f' * 64
        for records in self.records:
            records[1]['cases'][0]['frames'][0]['headerSHA256'] = audit.digest(audit.canonical(header))
        self.rejects('headerSHA256')

    def test_coherent_signed_zero_tamper_both_ranks(self):
        payload = bytearray(audit.fixture_bytes('float32', 32 * 128)); payload[3] = 128
        header, encoded = audit.wire_header(EPOCH, 'float32-h128', 'float32', 128, audit.frame_schedule()[0], bytes(payload))
        for records in self.records:
            frame = records[1]['cases'][0]['frames'][0]
            frame['payloadSHA256'] = header['payloadSHA256']; frame['headerSHA256'] = audit.digest(encoded)
        self.rejects('payloadSHA256')

    def test_scope_claim(self):
        self.records[0][1]['physicalTransferQualified'] = True
        self.rejects('physicalTransferQualified')

    def test_record_order(self):
        self.records[0].reverse()
        self.rejects('exact fields')

    def test_extra_jsonl_record(self):
        self.records[1].append(copy.deepcopy(self.records[1][1]))
        self.rejects('exactly ready then terminal')

    def test_duplicate_json_key(self):
        self.save()
        data = self.paths[0].read_bytes().replace(b'"rank":0', b'"rank":0,"rank":0', 1)
        self.paths[0].write_bytes(data)
        with self.assertRaisesRegex(ValueError, 'Duplicate JSON key'):
            audit.check_pair(self.paths, EPOCH)

    def test_oversized_file(self):
        self.save(); self.paths[0].write_bytes(b' ' * (audit.MAX_STDOUT_BYTES + 1))
        with self.assertRaisesRegex(ValueError, 'stdout empty/oversized'):
            audit.check_pair(self.paths, EPOCH)

    def test_nesting_bound(self):
        with self.assertRaisesRegex(ValueError, 'nesting exceeds'):
            audit.strict_json(b'{"x":' + b'[' * 13 + b'0' + b']' * 13 + b'}')

    def test_nonfinite_json(self):
        with self.assertRaisesRegex(ValueError, 'Nonfinite JSON'):
            audit.strict_json(b'{"x":NaN}')

    def test_epoch_admission(self):
        for epoch in [EPOCH.upper(), 'x' * 32, EPOCH[:-1], EPOCH + '0']:
            with self.subTest(epoch=epoch), self.assertRaisesRegex(ValueError, 'HEX32'):
                audit.request_fingerprint(epoch)


if __name__ == '__main__':
    unittest.main()
