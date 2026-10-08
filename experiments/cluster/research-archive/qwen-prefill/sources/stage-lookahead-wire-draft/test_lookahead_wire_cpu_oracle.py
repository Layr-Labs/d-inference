import copy
import json
from pathlib import Path
import tempfile
import unittest
import lookahead_wire_cpu_oracle as oracle

HERE = Path(__file__).resolve().parent


class LookaheadTests(unittest.TestCase):
    def setUp(self):
        self.header = oracle.boundary(oracle.frames()[0], 'bfloat16')
        self.raw = oracle.encoded(self.header)

    def test_actual_swift_vectors(self):
        summary = oracle.check_vectors(HERE / 'foundation-attempt-1/stdout.jsonl')
        self.assertEqual((summary['envelopeVectors'], summary['ACKVectors']), (21, 63))

    def test_raw_nested_duplicates(self):
        cases = [b'{"version":2,' + self.raw[1:], b'{"\\u0076ersion":2,' + self.raw[1:],
            self.raw.replace(b'"boundary":{', b'"boundary":{"version":1,'),
            self.raw.replace(b'"boundary":{', b'"boundary":{"\\u0076ersion":1,'),
            self.raw.replace(b'"frame":{', b'"frame":{"sequence":0,'),
            self.raw.replace(b'"frame":{', b'"frame":{"seque\\u006ece":0,')]
        for data in cases:
            with self.subTest(data=data[:60]):
                with self.assertRaisesRegex(ValueError, 'Duplicate'): oracle.decode(data, self.header)

    def test_integer_lexemes_before_normalization(self):
        for original, value in [(b'"version":2', b'"version":2.0'), (b'"version":1', b'"version":1e0'),
            (b'"sequence":0', b'"sequence":0.0'), (b'"tokenOffset":0', b'"tokenOffset":0E0'),
            (b'"tokenCount":32', b'"tokenCount":32e0'), (b'"byteCount":8192', b'"byteCount":8192.0'),
            (b'"shape":[1,32,128]', b'"shape":[1.0,32,128]'),
            (b'"shape":[1,32,128]', b'"shape":[1,32e0,128]'),
            (b'"shape":[1,32,128]', b'"shape":[1,32,128.0]')]:
            with self.subTest(value=value):
                with self.assertRaisesRegex(ValueError, 'Fraction/exponent'): oracle.decode(self.raw.replace(original, value), self.header)

    def test_boolean_integer_fields(self):
        for path in [('version',), ('boundary', 'version'), ('boundary', 'byteCount'),
            ('boundary', 'frame', 'sequence'), ('boundary', 'frame', 'tokenOffset'),
            ('boundary', 'frame', 'tokenCount'), ('boundary', 'shape', 0)]:
            obj = json.loads(self.raw); target = obj
            for key in path[:-1]: target = target[key]
            target[path[-1]] = True
            with self.subTest(path=path):
                with self.assertRaises(ValueError): oracle.decode(oracle.canonical(obj), self.header)

    def test_wrong_flow_and_v1(self):
        with self.assertRaises(ValueError): oracle.decode(oracle.canonical(self.header), self.header)
        for value in ['strict_v1', 'prompt_lookahead_two_v1', 'prompt_lookahead_one_v2', '', True, None]:
            obj = json.loads(self.raw); obj['flow'] = value
            with self.subTest(flow=value):
                with self.assertRaises(ValueError): oracle.decode(oracle.canonical(obj), self.header)

    def test_wrong_closed_schema(self):
        for path in [(), ('boundary',), ('boundary', 'frame')]:
            obj = json.loads(self.raw); target = obj
            for key in path: target = target[key]
            target['extra'] = 1
            with self.subTest(path=path):
                with self.assertRaises(ValueError): oracle.decode(oracle.canonical(obj), self.header)

    def test_phase_replay(self):
        for actual in oracle.PHASES:
            for expected in oracle.PHASES:
                if actual == expected: continue
                with self.subTest(actual=actual, expected=expected):
                    with self.assertRaises(ValueError): oracle.validate_ack(
                        oracle.ack_values(self.raw, actual, self.header), self.raw, expected, self.header)

    def test_v1_ack_replay_even_on_same_outer_bytes(self):
        values = list(oracle.sha(f'qwen-stage-ack-v1|ready|{oracle.sha(self.raw)}'.encode()).encode())
        with self.assertRaises(ValueError): oracle.validate_ack(values, self.raw, 'ready', self.header)

    def test_exact_outer_byte_replay(self):
        for variant, header, raw in oracle.cases()[-3:]:
            self.assertEqual(oracle.decode(raw, self.header), self.header)
            with self.subTest(variant=variant):
                with self.assertRaises(ValueError): oracle.validate_ack(
                    oracle.ack_values(self.raw, 'ready', self.header), raw, 'ready', self.header)

    def test_changed_header_digest_replay(self):
        header = copy.deepcopy(self.header); header['payloadSHA256'] = 'f' * 64
        raw = oracle.encoded(header)
        self.assertEqual(oracle.decode(raw, self.header), header)
        with self.assertRaises(ValueError): oracle.validate_ack(
            oracle.ack_values(self.raw, 'consumed', self.header), raw, 'consumed', self.header)

    def test_size_syntax_and_depth_bounds(self):
        cases = [b'', self.raw + b' ' * (oracle.LIMIT + 1 - len(self.raw)), b'[]', b'null', b'\xff',
            self.raw + b' null', b'[' * 66 + b'0' + b']' * 66,
            self.raw.replace(b'"version":2', b'"version":02'),
            self.raw.replace(b'"version":2', b'"version":NaN')]
        for data in cases:
            with self.subTest(data=data[:60]):
                with self.assertRaises(ValueError): oracle.decode(data, self.header)

    def test_tampered_swift_vector_is_rejected(self):
        rows = [oracle.strict_json(line) for line in (HERE / 'foundation-attempt-1/stdout.jsonl').read_bytes().splitlines()]
        rows[1]['vectors'][0]['acknowledgements'][0]['values'][0] += 1
        with tempfile.TemporaryDirectory(prefix='lookahead-vector-test-') as directory:
            path = Path(directory) / 'rows.jsonl'
            path.write_bytes(b'\n'.join(oracle.canonical(row) for row in rows) + b'\n')
            with self.assertRaises(ValueError): oracle.check_vectors(path)


if __name__ == '__main__': unittest.main()
