"""Token coordination and fixture dtype contracts, without model or network work."""

import copy
import unittest

from runtime import configuration, reports
from test_runtime_contract import run_spec
from test_runtime_reports import make_report, make_spec


class TokenSelectionReportTests(unittest.TestCase):
    def test_report_policy_must_match_the_backend_and_cannot_be_missing(self):
        for backend in ('solo', 'replicas', 'jaccl', 'loopback-test'):
            spec = make_spec(backend)
            expected = 'rank0-greedy' if backend in ('jaccl', 'loopback-test') else 'local-greedy'
            for value in (None, [], True, '', 'independent-greedy', 'teacher-forced',
                          'local-greedy' if expected == 'rank0-greedy' else 'rank0-greedy'):
                record = make_report(spec)
                record['tokenSelectionPolicy'] = value
                with self.subTest(backend=backend, value=value), self.assertRaises(ValueError):
                    reports.validate_report(record, spec, 0)
            record = make_report(spec)
            del record['tokenSelectionPolicy']
            with self.assertRaises(ValueError):
                reports.validate_report(record, spec, 0)

    def test_divergent_local_argmax_is_reported_but_never_becomes_rank_one_history(self):
        spec = make_spec('loopback-test')
        del spec['workload']['teacher_tokens']
        record = make_report(spec, 1)
        run = record['runs'][0]
        run.update(localArgmaxTokens=[7, 8, 9], localArgmaxDisagreementCount=3)
        reports.validate_report(record, spec, 1)
        run['decodeInputTokens'] = [7, 8]
        with self.assertRaisesRegex(ValueError, 'decodeInputTokens'):
            reports.validate_report(record, spec, 1)

    def test_selected_outputs_cannot_disagree_with_rank_zero_or_local_greedy(self):
        for backend in ('solo', 'replicas', 'loopback-test'):
            spec = make_spec(backend)
            record = make_report(spec)
            record['runs'][0].update(localArgmaxTokens=[7, 8, 9], localArgmaxDisagreementCount=3)
            with self.subTest(backend=backend), self.assertRaises(ValueError):
                reports.validate_report(record, spec, 0)

    def test_local_argmax_diagnostics_must_be_complete_consistent_and_in_bounds(self):
        spec = make_spec('loopback-test')
        for replacement in (dict(localArgmaxTokens=[1]), dict(localArgmaxTokens=[0, True, 2]),
                            dict(localArgmaxTokens=[0, -1, 2]), dict(localArgmaxTokens=[0, 512, 2]),
                            dict(localArgmaxDisagreementCount=1), dict(localArgmaxDisagreementCount=True)):
            record = make_report(spec, 1)
            record['runs'][0].update(replacement)
            with self.subTest(replacement=replacement), self.assertRaises(ValueError):
                reports.validate_report(record, spec, 1)
        for field in ('localArgmaxTokens', 'localArgmaxDisagreementCount', 'decodeInputTokens'):
            record = make_report(spec, 1)
            del record['runs'][0][field]
            with self.subTest(missing=field), self.assertRaises(ValueError):
                reports.validate_report(record, spec, 1)

    def test_teacher_history_remains_explicit_and_independent_of_selected_outputs(self):
        spec = make_spec('loopback-test')
        record = make_report(spec, 1)
        record['runs'][0].update(localArgmaxTokens=[7, 8, 9], localArgmaxDisagreementCount=3)
        reports.validate_report(record, spec, 1)
        record['runs'][0]['decodeInputTokens'] = record['runs'][0]['generatedTokens'][:-1]
        with self.assertRaises(ValueError):
            reports.validate_report(record, spec, 1)

    def test_vocabulary_and_generated_token_bounds_are_enforced(self):
        spec = make_spec()
        for value in (None, True, 3, 2**31, '512'):
            record = make_report(spec)
            record['vocabularySize'] = value
            with self.subTest(vocabulary=value), self.assertRaises(ValueError):
                reports.validate_report(record, spec, 0)
        record = make_report(spec)
        record['runs'][0]['generatedTokens'][0] = 512
        with self.assertRaises(ValueError):
            reports.validate_report(record, spec, 0)


class SyntheticDTypeTests(unittest.TestCase):
    def test_dtype_defaults_and_both_rank_arguments_are_bound(self):
        for dtype in ('float32', 'bfloat16'):
            raw = run_spec('loopback-test')
            if dtype != 'float32':
                raw['workload']['synthetic_dtype'] = dtype
            del raw['workload']['teacher_tokens']
            spec = configuration.validate(raw)
            self.assertEqual(spec['workload']['synthetic_dtype'], dtype)
            for rank in range(2):
                configured = configuration.rank_configuration(spec, rank, '/bundle', 'a' * 64, [])
                arguments = configured['arguments']
                self.assertEqual(arguments[arguments.index('--synthetic-dtype') + 1], dtype)
                self.assertNotIn('--teacher-tokens-file', arguments)

    def test_invalid_dtype_and_real_model_dtype_options_fail_closed(self):
        for value in (None, True, [], '', 'float16', 'BF16'):
            spec = run_spec()
            spec['workload']['synthetic_dtype'] = value
            with self.subTest(dtype=value), self.assertRaises(ValueError):
                configuration.validate(spec)
        for value in ('float32', 'bfloat16', None):
            spec = run_spec(synthetic=False)
            spec['workload']['synthetic_dtype'] = value
            with self.subTest(real_dtype=value), self.assertRaises(ValueError):
                configuration.validate(spec)

    def test_report_must_match_actual_and_requested_synthetic_dtype(self):
        for dtype in ('float32', 'bfloat16'):
            spec = make_spec('loopback-test', synthetic_dtype=dtype)
            record = make_report(spec)
            reports.validate_report(record, spec, 0)
            for field in ('syntheticDType', 'embeddingActivationDType', 'ffnScaleDTypes'):
                for value in (None, 'bfloat16' if dtype == 'float32' else 'float32'):
                    wrong = copy.deepcopy(record)
                    wrong[field] = [value] if field == 'ffnScaleDTypes' else value
                    with self.subTest(dtype=dtype, field=field), self.assertRaises(ValueError):
                        reports.validate_report(wrong, spec, 0)
            del record['syntheticDType']
            with self.assertRaises(ValueError):
                reports.validate_report(record, spec, 0)
        spec = make_spec(synthetic=False)
        record = make_report(spec)
        record['syntheticDType'] = None
        with self.assertRaises(ValueError):
            reports.validate_report(record, spec, 0)


if __name__ == '__main__':
    unittest.main()
