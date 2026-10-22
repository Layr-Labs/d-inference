"""Synthetic geometry identity and MoE shard accounting without native execution."""

import json
from pathlib import Path
import tempfile
import unittest

from runtime import configuration, reports
from test_runtime_contract import run_spec
from test_runtime_reports import make_report, make_spec


PROFILES = ('tiny', 'qwen9-heads', 'qwen27-heads', 'qwen-moe')


class SyntheticProfileTests(unittest.TestCase):
    def test_default_and_explicit_profiles_reach_both_ranks(self):
        raw = run_spec('loopback-test')
        self.assertEqual(configuration.validate(raw)['workload']['synthetic_profile'], 'tiny')
        for profile in PROFILES:
            for dtype in ('float32', 'bfloat16'):
                spec = make_spec('loopback-test', partition='full', synthetic_dtype=dtype,
                                 synthetic_profile=profile)
                for rank in range(2):
                    args = configuration.rank_configuration(spec, rank, '/bundle', 'a' * 64, [])['arguments']
                    self.assertEqual(args[args.index('--synthetic-profile') + 1], profile)
                    self.assertEqual(args[args.index('--synthetic-dtype') + 1], dtype)
                    record = make_report(spec, rank)
                    reports.validate_report(record, spec, rank)
                    self.assertEqual(record['feedForwardKind'], 'moe' if profile == 'qwen-moe' else 'dense')

    def test_unknown_or_malformed_profiles_are_rejected(self):
        for value in (None, True, [], {}, '', 'qwen27', 27):
            raw = run_spec('solo')
            raw['workload']['synthetic_profile'] = value
            with self.subTest(value=value), self.assertRaises(ValueError):
                configuration.validate(raw)

    def test_real_weights_cannot_accept_or_report_fixture_profiles(self):
        for value in (*PROFILES, None):
            spec = make_spec(synthetic=False)
            spec['workload']['synthetic_profile'] = value
            with self.subTest(value=value), self.assertRaises(ValueError):
                configuration.validate(spec)
            spec = make_spec(synthetic=False)
            record = make_report(spec)
            record['syntheticProfile'] = value
            with self.assertRaisesRegex(ValueError, 'syntheticProfile'):
                reports.validate_report(record, spec, 0)

    def test_reports_require_exact_requested_profile_and_feed_forward_kind(self):
        for profile in PROFILES:
            spec = make_spec('loopback-test', synthetic_profile=profile)
            for field in ('syntheticProfile', 'feedForwardKind'):
                record = make_report(spec)
                del record[field]
                with self.subTest(profile=profile, missing=field), self.assertRaises(ValueError):
                    reports.validate_report(record, spec, 0)
            for field, value in (('syntheticProfile', 'tiny' if profile != 'tiny' else 'qwen9-heads'),
                                 ('feedForwardKind', 'dense' if profile == 'qwen-moe' else 'moe'),
                                 ('feedForwardKind', None), ('feedForwardKind', [])):
                record = make_report(spec)
                record[field] = value
                with self.subTest(profile=profile, field=field, value=value), self.assertRaises(ValueError):
                    reports.validate_report(record, spec, 0)


class MoEReceiptTests(unittest.TestCase):
    def make_moe(self, partition='ffn', rank=0):
        spec = make_spec('jaccl', synthetic=False, partition=partition)
        record = make_report(spec, rank)
        record['feedForwardKind'] = 'moe'
        # 80 of the 600 FFN bytes are replicated routers; only 520 are sliced.
        sharded = 520 if partition == 'ffn' else 720
        record['directShardLoad'].update(sourceShardedFFNTensorBytes=520,
                                        sourceShardedTensorBytes=sharded,
                                        loadedTensorBytes=1000 - sharded // 2,
                                        sourceTensorCount=54)
        return spec, record

    def test_router_bytes_are_replicated_for_both_partition_modes(self):
        for partition in ('ffn', 'full'):
            spec, record = self.make_moe(partition)
            reports.validate_report(record, spec, 0)
            record['directShardLoad']['loadedTensorBytes'] -= 40
            with self.subTest(partition=partition), self.assertRaisesRegex(ValueError, 'byte accounting'):
                reports.validate_report(record, spec, 0)

    def test_sharded_ffn_subset_is_required_bounded_even_and_not_boolean(self):
        for value in (None, True, '520', 0, -2, 519, 602, 1002):
            spec, record = self.make_moe('full')
            record['directShardLoad']['sourceShardedFFNTensorBytes'] = value
            with self.subTest(value=value), self.assertRaises(ValueError):
                reports.validate_report(record, spec, 0)
        spec, record = self.make_moe()
        del record['directShardLoad']['sourceShardedFFNTensorBytes']
        with self.assertRaisesRegex(ValueError, 'sourceShardedFFNTensorBytes'):
            reports.validate_report(record, spec, 0)

    def test_total_sharded_bytes_must_cover_sharded_ffn_subset(self):
        spec, record = self.make_moe('full')
        record['directShardLoad'].update(sourceShardedTensorBytes=500, loadedTensorBytes=750)
        with self.assertRaisesRegex(ValueError, 'byte accounting'):
            reports.validate_report(record, spec, 0)

    def test_source_tensor_count_covers_materialized_canonical_tensors(self):
        spec, record = self.make_moe()
        reports.validate_report(record, spec, 0)
        for value in (None, True, 0, 41, '54'):
            spec, record = self.make_moe()
            record['directShardLoad']['sourceTensorCount'] = value
            with self.subTest(value=value), self.assertRaises(ValueError):
                reports.validate_report(record, spec, 0)
        spec, record = self.make_moe()
        del record['directShardLoad']['sourceTensorCount']
        with self.assertRaisesRegex(ValueError, 'sourceTensorCount'):
            reports.validate_report(record, spec, 0)

    def test_partition_kind_compares_to_sharded_ffns_not_all_ffn_bytes(self):
        spec, record = self.make_moe('full')
        # A full plan can legitimately shard 600 bytes while FFNs also total 600:
        # its 80 sharded attention bytes differ from the 80 replicated router bytes.
        record['directShardLoad'].update(sourceShardedTensorBytes=600, loadedTensorBytes=700)
        reports.validate_report(record, spec, 0)
        record['directShardLoad'].update(sourceShardedTensorBytes=520, loadedTensorBytes=740)
        with self.assertRaisesRegex(ValueError, 'requested partition'):
            reports.validate_report(record, spec, 0)
        spec, record = self.make_moe('ffn')
        record['directShardLoad'].update(sourceShardedTensorBytes=600, loadedTensorBytes=700)
        with self.assertRaisesRegex(ValueError, 'requested partition'):
            reports.validate_report(record, spec, 0)

    def test_cross_rank_subset_and_feed_forward_kind_must_agree(self):
        for field, value in (('sourceShardedFFNTensorBytes', 518), ('sourceTensorCount', 55),
                             ('feedForwardKind', 'dense')):
            spec, first = self.make_moe('full')
            _, second = self.make_moe('full', rank=1)
            target = second if field == 'feedForwardKind' else second['directShardLoad']
            target[field] = value
            reports.validate_report(second, spec, 1)
            with tempfile.TemporaryDirectory() as temporary:
                ranks = []
                for index, record in enumerate((first, second)):
                    directory = Path(temporary) / str(index)
                    directory.mkdir()
                    (directory / 'stdout.jsonl').write_text(json.dumps(record) + '\n')
                    ranks.append(dict(rank=index, local=str(directory)))
                with self.subTest(field=field), self.assertRaisesRegex(ValueError, 'disagree'):
                    reports.reports(ranks, spec)


if __name__ == '__main__':
    unittest.main()
