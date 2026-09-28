"""Small independent CPU controls for the post-norm cast audit."""

import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('audit', Path(__file__).with_name('audit-gemma-through-norm.py'))
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)


def refresh_hash(record):
    words = [struct.unpack('<I', struct.pack('<f', value))[0] for value in record['values']]
    raw = b''.join(struct.pack('<I', word) if record['dtype'] == 'float32'
                   else struct.pack('<H', word >> 16) for word in words)
    record['nativeSHA256'] = hashlib.sha256(raw).hexdigest()


def fixture(rank, world):
    identity = dict(configurationSHA256='a' * 64, syntheticProfile='gemma-moe', syntheticDType='bfloat16',
                    ffnBranchPrecision='float32-through-norm', seed='7', promptSHA256='b' * 64,
                    teacherSHA256='c' * 64, chunkSize='1', rank=str(rank), worldSize=str(world),
                    partition='none' if world == 1 else 'ffn', partitionPlanSHA256='none' if world == 1 else 'd' * 64)
    records = []
    branch_stages = [('branch.input', 'bfloat16'), ('input_norm', 'bfloat16'), ('projection.input', 'float32'),
                     ('branch.local', 'float32'), ('branch.reduced', 'float32'), ('output_norm.input', 'float32'),
                     ('output_norm.output', 'float32'), ('branch.output', 'bfloat16')]
    for layer in range(4):
        for module, stages in [('post_attention_layernorm', [('norm.input', 'bfloat16'), ('norm.output', 'bfloat16')]),
                               ('post_feedforward_layernorm_1', branch_stages),
                               ('router.proj', [('router.input', 'bfloat16'), ('router.logits', 'bfloat16')]),
                               ('post_feedforward_layernorm_2', branch_stages),
                               ('post_feedforward_layernorm', [('norm.input', 'bfloat16'), ('norm.output', 'bfloat16')])]:
            for stage, dtype in stages:
                width = 4 if stage == 'router.logits' else 128
                value = 1.00390625 if stage == 'output_norm.output' else 1.0
                record = dict(path=f'language_model.model.layers.{layer}.{module}', stage=stage, call=0,
                              tokenStart=0, shape=[1, 1, width], dtype=dtype, values=[value] * width)
                refresh_hash(record)
                records.append(record)
    return dict(schemaVersion=1, correctnessOnly=True, evaluationSchedule='explicit-chunks-full-logits-and-captures',
                routerIDsAreReplayed=True, identity=identity, tokensPerBoundary=1, records=records)


class ThroughNormAuditTests(unittest.TestCase):
    def inspect(self, traces):
        with tempfile.TemporaryDirectory() as temporary:
            paths = []
            for rank, trace in enumerate(traces):
                path = Path(temporary) / f'{rank}.json'
                path.write_text(json.dumps(trace))
                paths.append(path)
            return audit.audit(paths)

    def test_integer_rounding_has_independent_tie_sign_and_subnormal_controls(self):
        pairs = [(0x00000000, 0x0000), (0x80000000, 0x8000), (0x3f808000, 0x3f80),
                 (0x3f818000, 0x3f82), (0xbf808000, 0xbf80), (0xbf818000, 0xbf82),
                 (0x00008000, 0x0000), (0x00018000, 0x0002), (0x80018000, 0x8002),
                 (0x3f807fff, 0x3f80), (0x3f808001, 0x3f81)]
        for source, expected in pairs:
            self.assertEqual(audit.nearest_even_bf16(struct.pack('<I', source)), struct.pack('<H', expected))

    def test_complete_fixture_checks_every_branch_and_scalar(self):
        result = self.inspect([fixture(0, 1), fixture(0, 2), fixture(1, 2)])
        self.assertEqual(sum(item['counts']['nativeHashes'] for item in result), 264)
        self.assertEqual(sum(item['counts']['castValues'] for item in result), 3072)
        self.assertTrue(all(item['counts']['widenedValues'] == 1024 for item in result))

    def test_boundary_corruption_rejects_even_when_native_hash_is_recomputed(self):
        for stage in ('projection.input', 'output_norm.input', 'branch.output'):
            traces = [fixture(0, 1), fixture(0, 2), fixture(1, 2)]
            record = next(item for item in traces[1]['records'] if item['stage'] == stage)
            record['values'][0] = 1.0078125
            refresh_hash(record)
            with self.subTest(stage=stage), self.assertRaisesRegex(ValueError, 'boundary conversion'):
                self.inspect(traces)

    def test_dtype_hash_and_coordinate_guards(self):
        base = [fixture(0, 1), fixture(0, 2), fixture(1, 2)]
        for field, value in [('dtype', 'float32'), ('nativeSHA256', 'e' * 64),
                             ('tokenStart', 1), ('call', 1), ('shape', [1, 2, 128])]:
            traces = copy.deepcopy(base)
            traces[0]['records'][0][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.inspect(traces)

    def test_missing_stage_old_policy_and_peer_identity_reject(self):
        for fault in ('stage', 'policy', 'seed'):
            traces = [fixture(0, 1), fixture(0, 2), fixture(1, 2)]
            if fault == 'stage':
                traces[0]['records'].pop()
            elif fault == 'policy':
                traces[0]['identity']['ffnBranchPrecision'] = 'float32'
            else:
                traces[2]['identity']['seed'] = '31'
            with self.subTest(fault=fault), self.assertRaises(ValueError):
                self.inspect(traces)


if __name__ == '__main__':
    unittest.main()
