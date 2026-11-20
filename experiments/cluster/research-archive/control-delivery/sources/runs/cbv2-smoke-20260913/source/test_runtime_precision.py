"""Bind experimental attention output precision to workload, CLI and reports."""

import json
from pathlib import Path
import tempfile
import unittest

from runtime import configuration, reports
from test_runtime_contract import run_spec
from test_runtime_reports import make_report, make_spec


class AttentionOutputPrecisionTests(unittest.TestCase):
    def test_default_is_explicit_for_real_and_synthetic_workloads(self):
        for synthetic in (True, False):
            raw = run_spec(synthetic=synthetic)
            self.assertNotIn('attention_output_precision', raw['workload'])
            spec = configuration.validate(raw)
            self.assertEqual(spec['workload']['attention_output_precision'], 'native')
            args = configuration.rank_configuration(spec, 0, '/bundle', 'a' * 64, [])['arguments']
            self.assertEqual(args[args.index('--attention-output-precision') + 1], 'native')

    def test_both_policies_reach_every_rank_and_validate_for_all_supported_execution_types(self):
        for backend in ('solo', 'replicas', 'jaccl', 'loopback-test'):
            for synthetic in (True, False):
                if backend == 'loopback-test' and not synthetic:
                    continue
                partitions = ('ffn', 'full') if backend in ('jaccl', 'loopback-test') else ('ffn',)
                for partition in partitions:
                    for precision in ('native', 'float32'):
                        with self.subTest(backend=backend, synthetic=synthetic,
                                          partition=partition, precision=precision):
                            spec = make_spec(backend, synthetic=synthetic, partition=partition,
                                             attention_output_precision=precision)
                            rank_arguments = []
                            for rank in range(len(spec['ranks'])):
                                args = configuration.rank_configuration(spec, rank, '/bundle', 'a' * 64, [])['arguments']
                                self.assertEqual(args.count('--attention-output-precision'), 1)
                                self.assertEqual(args[args.index('--attention-output-precision') + 1], precision)
                                rank_arguments.append(args)
                                report = make_report(spec, rank)
                                self.assertEqual(report['schemaVersion'], 8)
                                self.assertEqual(report['attentionOutputPrecision'], precision)
                                reports.validate_report(report, spec, rank)
                            self.assertTrue(all(args == rank_arguments[0] for args in rank_arguments))

    def test_unknown_or_malformed_workload_precision_is_rejected(self):
        for synthetic in (True, False):
            for value in (None, True, False, 0, 32, 1.0, [], {}, '', 'bf16', 'float16', 'Float32', ' native'):
                raw = run_spec(synthetic=synthetic)
                raw['workload']['attention_output_precision'] = value
                with self.subTest(synthetic=synthetic, value=value), self.assertRaisesRegex(ValueError, 'precision'):
                    configuration.validate(raw)

    def test_report_precision_is_required_and_must_equal_requested_policy(self):
        for precision in ('native', 'float32'):
            for synthetic in (True, False):
                spec = make_spec(synthetic=synthetic, attention_output_precision=precision)
                record = make_report(spec)
                del record['attentionOutputPrecision']
                with self.assertRaisesRegex(ValueError, 'attentionOutputPrecision'):
                    reports.validate_report(record, spec, 0)
                opposite = 'float32' if precision == 'native' else 'native'
                for value in (opposite, None, True, 32, [], {}, '', 'float16', 'NATIVE'):
                    record = make_report(spec)
                    record['attentionOutputPrecision'] = value
                    with self.subTest(precision=precision, synthetic=synthetic, value=value), \
                            self.assertRaisesRegex(ValueError, 'attentionOutputPrecision'):
                        reports.validate_report(record, spec, 0)

    def test_cohort_rejects_rank_policy_mismatch(self):
        for backend in ('replicas', 'jaccl', 'loopback-test'):
            for requested in ('native', 'float32'):
                spec = make_spec(backend, attention_output_precision=requested)
                records = [make_report(spec, rank) for rank in range(2)]
                other = make_spec(backend, attention_output_precision='float32' if requested == 'native' else 'native')
                records[1] = make_report(other, 1)
                # Each rank's report is valid for its own policy, but the cohort
                # must not accept two policies under one shared workload.
                reports.validate_report(records[1], other, 1)
                with tempfile.TemporaryDirectory() as temporary:
                    ranks = []
                    for rank, record in enumerate(records):
                        directory = Path(temporary) / str(rank)
                        directory.mkdir()
                        (directory / 'stdout.jsonl').write_text(json.dumps(record) + '\n')
                        ranks.append(dict(rank=rank, local=str(directory)))
                    with self.subTest(backend=backend, requested=requested), \
                            self.assertRaisesRegex(ValueError, 'attentionOutputPrecision'):
                        reports.reports(ranks, spec)


if __name__ == '__main__':
    unittest.main()
