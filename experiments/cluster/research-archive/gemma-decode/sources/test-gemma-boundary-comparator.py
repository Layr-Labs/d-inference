"""Independent CPU fixtures for the outside-repository boundary comparator."""

import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest

path = Path(__file__).with_name('compare-gemma-boundaries.py')
spec = importlib.util.spec_from_file_location('gemma_comparator', path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def fixture(rank=None, bf16=False):
    dtype = 'bfloat16' if bf16 else 'float32'
    identity = dict(configurationSHA256='a' * 64, promptSHA256='b' * 64, teacherSHA256='c' * 64,
                    syntheticProfile='gemma-moe', syntheticDType=dtype, ffnBranchPrecision='native' if bf16 else 'float32',
                    seed='7', chunkSize='1', rank=str(rank or 0), worldSize='1' if rank is None else '2',
                    partition='none' if rank is None else 'ffn', partitionPlanSHA256='none' if rank is None else 'd' * 64)
    records = []
    for layer in range(4):
        for name in ('post_feedforward_layernorm_1', 'post_feedforward_layernorm_2',
                     'post_attention_layernorm', 'post_feedforward_layernorm', 'router.proj'):
            path = f'language_model.model.layers.{layer}.{name}'
            stages = (['branch.input', 'input_norm', 'projection.input', 'branch.local', 'branch.reduced',
                       'output_norm.input', 'output_norm.output'] if name.endswith(('_1', '_2')) else
                      ['router.input', 'router.logits'] if name == 'router.proj' else ['norm.input', 'norm.output'])
            for stage in stages:
                values = [4., 3., 2., 1.] if stage == 'router.logits' else [.75] * 128
                if stage == 'branch.local' and rank is not None:
                    values = [.25 if rank == 0 else .5] * 128
                record = dict(path=path, stage=stage, call=0, tokenStart=0, shape=[1, 1, len(values)],
                              dtype=dtype, values=values)
                stamp(record)
                if stage == 'router.logits': record['replayedExpertIDs'] = [0, 1]
                records.append(record)
    return dict(schemaVersion=1, correctnessOnly=True, routerIDsAreReplayed=True,
                evaluationSchedule='explicit-chunks-full-logits-and-captures', identity=identity,
                tokensPerBoundary=1, records=records)


def stamp(record):
    # Independent scalar packing matches original little-endian tensor bytes.
    chunks = [struct.pack('<f', value) for value in record['values']]
    raw = b''.join(chunk[2:] if record['dtype'] == 'bfloat16' else chunk for chunk in chunks)
    record['nativeSHA256'] = hashlib.sha256(raw).hexdigest()


class ComparatorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.sequence = 0

    def load(self, value):
        self.sequence += 1
        file = Path(self.temp.name) / f'{self.sequence}.json'
        file.write_text(json.dumps(value))
        return module.load_trace(file)

    def compare(self, values):
        return module.compare([self.load(value) for value in values])

    def test_complete_sum_and_peers_are_exact_despite_unequal_local_partials(self):
        result = self.compare([fixture(None), fixture(0), fixture(1)])
        self.assertTrue(result['peerExactExceptLocal'])
        self.assertEqual(result['float32PartialSumChecks'], 8)
        self.assertEqual(result['float32PartialSumFailures'], 0)
        self.assertIsNone(result['firstSharedBoundaryDifference'])
        self.assertEqual(result['firstDifferenceIncludingExpectedPartials']['stage'], 'branch.local')

    def test_one_round_float32_sum_and_mismatch_are_checked(self):
        values = [fixture(None), fixture(0), fixture(1)]
        for rank, value in enumerate(values):
            for record in value['records']:
                if record['stage'] == 'branch.local':
                    record['values'][0] = 1.0 if rank == 2 else 16777216.0
                if record['stage'] == 'branch.reduced': record['values'][0] = 16777216.0
                stamp(record)
        self.assertEqual(self.compare(values)['float32PartialSumFailures'], 0)
        for value in values[1:]:
            for record in value['records']:
                if record['stage'] == 'branch.reduced': record['values'][0] = 16777218.0
                stamp(record)
        result = self.compare(values)
        self.assertTrue(result['peerExactExceptLocal'])
        self.assertEqual(result['float32PartialSumFailures'], 8)

    def test_peer_mismatch_is_reported_even_when_local_difference_is_permitted(self):
        values = [fixture(None), fixture(0), fixture(1)]
        values[2]['records'][0]['values'][0] += .25
        stamp(values[2]['records'][0])
        result = self.compare(values)
        self.assertFalse(result['peerExactExceptLocal'])
        self.assertEqual(result['peerMismatchCount'], 1)

    def test_identity_mismatch_and_unknown_fields_are_rejected(self):
        for mutate in (lambda value: value['identity'].update(ffnBranchPrecision='native'),
                       lambda value: value['identity'].update(seed='8'),
                       lambda value: value['identity'].update(extra='x')):
            values = [fixture(None), fixture(0), fixture(1)]; mutate(values[1])
            with self.assertRaises(ValueError): self.compare(values)

    def test_native_hash_shape_coordinates_finiteness_and_coverage_reject_tampering(self):
        for mutate in (lambda value: value['records'][0]['values'].__setitem__(0, 2.0),
                       lambda value: value['records'][0].update(shape=[1, 1, 127]),
                       lambda value: value['records'][0].update(call=1),
                       lambda value: value['records'][0]['values'].__setitem__(0, float('inf')),
                       lambda value: value['records'].pop(),
                       lambda value: value.update(extra=True)):
            value = fixture(); mutate(value)
            with self.assertRaises(ValueError): self.load(value)

    def test_bf16_reconstruction_is_exact_and_sum_check_explicitly_skips(self):
        result = self.compare([fixture(None, True), fixture(0, True), fixture(1, True)])
        self.assertEqual(result['nativeBF16SumChecksSkipped'], 8)
        value = fixture(None, True); value['records'][0]['values'][0] = 0.75001
        with self.assertRaisesRegex(ValueError, 'rounding'): self.load(value)

    def test_replayed_routes_are_admissible_and_ties_are_not_invented(self):
        values = [fixture(None), fixture(0), fixture(1)]
        for value in values[1:]:
            for record in value['records']:
                if record['stage'] == 'router.logits':
                    record.update(values=[4., 2., 3., 1.], replayedExpertIDs=[0, 2]); stamp(record)
        result = self.compare(values)
        self.assertEqual(result['changedRouterSets'], 4)
        for value in values:
            for record in value['records']:
                if record['stage'] == 'router.logits':
                    record.pop('replayedExpertIDs'); record['values'] = [4., 3., 3., 1.]; stamp(record)
        result = self.compare(values)
        self.assertEqual(result['unresolvedRouterTieRows'], 4)
        self.assertEqual(result['referenceRouterCutoffTies'], 4)
        invalid = fixture()
        next(r for r in invalid['records'] if r['stage'] == 'router.logits')['replayedExpertIDs'] = [2, 3]
        with self.assertRaisesRegex(ValueError, 'admissible'): self.load(invalid)


if __name__ == '__main__': unittest.main(verbosity=2)
