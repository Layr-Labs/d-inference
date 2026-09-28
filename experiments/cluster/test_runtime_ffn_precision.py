"""Bind the experimental Gemma FFN branch policy across launch and worker identity."""

import copy
import json
from pathlib import Path
import tempfile
import unittest

from runtime import configuration, reports
from runtime import persistent_protocol as protocol
from runtime.persistent import PersistentCohort, PersistentCohortError
from runtime.persistent_processes import configure
from persistent_test_support import PersistentFixture, cohort_spec
from test_persistent_protocol import EPOCH, ready_fixture
from test_runtime_contract import run_spec
from test_runtime_reports import make_report, make_spec


PRECISIONS = ('native', 'float32', 'float32-through-norm')


class FFNBranchPrecisionTests(unittest.TestCase):
    def test_default_native_is_explicit_for_real_and_synthetic_models(self):
        for synthetic in (True, False):
            raw = run_spec(synthetic=synthetic)
            self.assertNotIn('ffn_branch_precision', raw['workload'])
            spec = configuration.validate(raw)
            self.assertEqual(spec['workload']['ffn_branch_precision'], 'native')
            args = configuration.rank_configuration(spec, 0, '/bundle', 'a' * 64, [])['arguments']
            self.assertEqual(args.count('--ffn-branch-precision'), 1)
            self.assertEqual(args[args.index('--ffn-branch-precision') + 1], 'native')

    def test_gemma_policy_reaches_each_rank_report_and_worker_configuration(self):
        for backend in ('solo', 'replicas', 'jaccl', 'loopback-test'):
            for profile in ('gemma-moe', 'gemma-moe-w8'):
                for dtype in ('float32', 'bfloat16'):
                    for precision in PRECISIONS:
                        spec = make_spec(backend, synthetic_profile=profile, synthetic_dtype=dtype,
                                         ffn_branch_precision=precision)
                        for rank in range(len(spec['ranks'])):
                            with self.subTest(backend=backend, profile=profile, dtype=dtype, precision=precision, rank=rank):
                                config = configuration.rank_configuration(spec, rank, '/bundle', 'a' * 64, [])
                                args = config['arguments']
                                self.assertEqual(args.count('--ffn-branch-precision'), 1)
                                self.assertEqual(args[args.index('--ffn-branch-precision') + 1], precision)
                                report = make_report(spec, rank)
                                self.assertEqual(report['schemaVersion'], 9)
                                self.assertEqual(report['ffnBranchPrecision'], precision)
                                reports.validate_report(report, spec, rank)
                                if backend == 'replicas':
                                    continue
                                with tempfile.TemporaryDirectory() as temporary:
                                    path = Path(temporary) / 'rank.json'
                                    path.write_text(json.dumps(config))
                                    configure(dict(local=temporary, host=None), spec, EPOCH)
                                    worker = json.loads(path.read_text())['arguments']
                                    self.assertEqual(worker[worker.index('--ffn-branch-precision') + 1], precision)
                                _, ready = ready_fixture(spec, rank)
                                protocol.ready(ready, EPOCH, rank, spec)
                                self.assertEqual(ready['identity']['ffnBranchPrecision'], precision)

    def test_real_model_policy_is_gated_by_native_family_identity(self):
        for backend in ('solo', 'jaccl'):
            for precision in PRECISIONS[1:]:
                spec = make_spec(backend, synthetic=False, ffn_branch_precision=precision)
                for rank in range(len(spec['ranks'])):
                    with self.subTest(backend=backend, precision=precision, rank=rank):
                        record = make_report(spec, rank)
                        with self.assertRaisesRegex(ValueError, 'Gemma'): reports.validate_report(record, spec, rank)
                        record['modelFamily'] = 'gemma4'
                        reports.validate_report(record, spec, rank)
                        _, ready = ready_fixture(spec, rank)
                        with self.assertRaisesRegex(PersistentCohortError, 'Gemma'): protocol.ready(ready, EPOCH, rank, spec)
                        ready['identity']['modelFamily'] = 'gemma4'
                        ready['identitySHA256'] = protocol.hash_frame(ready['identity'])
                        protocol.ready(ready, EPOCH, rank, spec)

    def test_qwen_synthetic_nonnative_policy_is_rejected_before_launch(self):
        for profile in ('tiny', 'qwen9-heads', 'qwen27-heads', 'qwen-moe'):
            for precision in PRECISIONS[1:]:
                with self.subTest(profile=profile, precision=precision), self.assertRaisesRegex(ValueError, 'Gemma'):
                    make_spec('loopback-test', synthetic_profile=profile, ffn_branch_precision=precision)

    def test_malformed_workload_policy_is_rejected(self):
        for synthetic in (True, False):
            for value in (None, True, False, 0, 32, 1.0, [], {}, '', 'bf16', 'Float32', ' native',
                          'float32-through-norm ', 'float32-through-norm-unknown'):
                with self.subTest(synthetic=synthetic, value=value), self.assertRaisesRegex(ValueError, 'precision'):
                    make_spec(synthetic=synthetic, synthetic_profile='gemma-moe', ffn_branch_precision=value)

    def test_report_and_ready_policy_is_required_and_must_match_workload(self):
        for requested in PRECISIONS:
            spec = make_spec('loopback-test', synthetic_profile='gemma-moe', ffn_branch_precision=requested)
            mismatches = tuple(value for value in PRECISIONS if value != requested)
            for value in (None, True, [], {}, 'float16', 'float32-through-norm-unknown') + mismatches:
                record = make_report(spec); record['ffnBranchPrecision'] = value
                with self.assertRaisesRegex(ValueError, 'ffnBranchPrecision'): reports.validate_report(record, spec, 0)
                _, ready = ready_fixture(spec); ready['identity']['ffnBranchPrecision'] = value
                ready['identitySHA256'] = protocol.hash_frame(ready['identity'])
                with self.assertRaisesRegex(PersistentCohortError, 'ffnBranchPrecision'):
                    protocol.ready(ready, EPOCH, 0, spec)
            record = make_report(spec); del record['ffnBranchPrecision']
            with self.assertRaises(ValueError): reports.validate_report(record, spec, 0)
            _, ready = ready_fixture(spec); del ready['identity']['ffnBranchPrecision']
            ready['identitySHA256'] = protocol.hash_frame(ready['identity'])
            with self.assertRaises(PersistentCohortError): protocol.ready(ready, EPOCH, 0, spec)

    def test_old_versions_remain_rejected_even_with_new_policy_present(self):
        spec = make_spec(synthetic_profile='gemma-moe', ffn_branch_precision='float32-through-norm')
        _, ready = ready_fixture(spec)
        for version in (1, 2, 3, 4):
            bad = copy.deepcopy(ready); bad['version'] = version
            with self.assertRaises(PersistentCohortError): protocol.ready(bad, EPOCH, 0, spec)
        record = make_report(spec); record['schemaVersion'] = 6
        with self.assertRaises(ValueError): reports.validate_report(record, spec, 0)

    def test_cohort_rejects_individually_valid_reports_for_different_policies(self):
        for requested in PRECISIONS:
            for observed in PRECISIONS:
                if requested == observed:
                    continue
                with self.subTest(requested=requested, observed=observed):
                    spec = make_spec('loopback-test', synthetic_profile='gemma-moe', ffn_branch_precision=requested)
                    other = make_spec('loopback-test', synthetic_profile='gemma-moe', ffn_branch_precision=observed)
                    records = [make_report(spec, 0), make_report(other, 1)]
                    reports.validate_report(records[1], other, 1)
                    with tempfile.TemporaryDirectory() as temporary:
                        ranks = []
                        for rank, record in enumerate(records):
                            directory = Path(temporary) / str(rank)
                            directory.mkdir()
                            (directory / 'stdout.jsonl').write_text(json.dumps(record) + '\n')
                            ranks.append(dict(rank=rank, local=str(directory)))
                        with self.assertRaisesRegex(ValueError, 'ffnBranchPrecision'): reports.reports(ranks, spec)

    def test_each_policy_has_a_distinct_common_worker_identity(self):
        identities = []
        for precision in PRECISIONS:
            spec = make_spec('loopback-test', synthetic_profile='gemma-moe', ffn_branch_precision=precision)
            peers = [ready_fixture(spec, rank)[1] for rank in range(2)]
            for rank, ready in enumerate(peers):
                protocol.ready(ready, EPOCH, rank, spec)
            self.assertEqual(peers[0]['identitySHA256'], peers[1]['identitySHA256'])
            identities.append(peers[0]['identitySHA256'])
        self.assertEqual(len(set(identities)), len(PRECISIONS))

    def test_policy_mismatch_fences_actual_fixture_cohort_before_requests(self):
        for precision in PRECISIONS[1:]:
            with self.subTest(precision=precision):
                fixture = PersistentFixture({'1': 'wrong_ffn_precision'})
                self.addCleanup(fixture.cleanup)
                spec = cohort_spec()
                spec['workload'].update(synthetic_profile='gemma-moe', ffn_branch_precision=precision)
                cohort = PersistentCohort(spec, fixture.source, fixture.output)
                self.addCleanup(cohort.close)
                with self.assertRaisesRegex(PersistentCohortError, 'ffnBranchPrecision'): cohort.start()
                fixture.assert_stopped()
                self.assertEqual(cohort.state, 'failed')
                with self.assertRaises(PersistentCohortError): cohort.infer('no-reuse', [3], 1, 1)

    def test_gemma_nonnative_fixture_policies_survive_persistent_reuse_and_shutdown(self):
        for precision in PRECISIONS[1:]:
            with self.subTest(precision=precision):
                fixture = PersistentFixture()
                self.addCleanup(fixture.cleanup)
                spec = cohort_spec()
                spec['workload'].update(synthetic_profile='gemma-moe-w8', ffn_branch_precision=precision)
                with PersistentCohort(spec, fixture.source, fixture.output) as cohort:
                    self.assertTrue(all(r['version'] == 5 and r['identity']['ffnBranchPrecision'] == precision
                                        for r in cohort.ready))
                    first = cohort.infer('a', [3, 5], 2, 2)
                    second = cohort.infer('b', [3, 5], 2, 2)
                    self.assertEqual(first[0]['result']['generatedTokens'], second[0]['result']['generatedTokens'])
                    self.assertEqual(first[0]['modelLoadID'], second[0]['modelLoadID'])
                fixture.assert_stopped()


if __name__ == '__main__':
    unittest.main()
