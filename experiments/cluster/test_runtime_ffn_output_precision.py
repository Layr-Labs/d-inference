"""Dense Qwen FFN output policy admission, identity, and process fencing."""

import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from persistent_test_support import PersistentFixture, cohort_spec
from runtime import configuration, reports
from runtime import persistent_protocol as protocol
from runtime.persistent import PersistentCohort, PersistentCohortError
from runtime.persistent_processes import configure
from test_persistent_protocol import EPOCH, ready_fixture
from test_runtime_contract import run_spec
from test_runtime_reports import make_report, make_spec


class FFNOutputPrecisionTests(unittest.TestCase):
    def test_native_default_is_explicit_and_forwarded_for_real_and_synthetic_models(self):
        for synthetic in (True, False):
            raw = run_spec(synthetic=synthetic)
            self.assertNotIn('ffn_output_precision', raw['workload'])
            spec = configuration.validate(raw)
            self.assertEqual(spec['workload']['ffn_output_precision'], 'native')
            arguments = configuration.rank_configuration(spec, 0, '/bundle', 'a' * 64, [])['arguments']
            self.assertEqual(arguments.count('--ffn-output-precision'), 1)
            self.assertEqual(arguments[arguments.index('--ffn-output-precision') + 1], 'native')

    def test_dense_qwen_policy_survives_all_supported_paths_and_rank_configurations(self):
        for backend in ('solo', 'replicas', 'jaccl', 'loopback-test'):
            partitions = ('ffn', 'full') if backend in ('jaccl', 'loopback-test') else ('ffn',)
            for partition in partitions:
                for profile in ('tiny', 'qwen9-heads', 'qwen27-heads'):
                    for dtype in ('float32', 'bfloat16'):
                        for path in ('ordinary', 'cbv2-contiguous'):
                            for attention in ('native', 'float32'):
                                spec = make_spec(backend, partition=partition, synthetic_profile=profile,
                                                 synthetic_dtype=dtype, execution_path=path,
                                                 attention_output_precision=attention, ffn_output_precision='float32')
                                for rank in range(len(spec['ranks'])):
                                    with self.subTest(backend=backend, partition=partition, profile=profile,
                                                      dtype=dtype, path=path, attention=attention, rank=rank):
                                        config = configuration.rank_configuration(spec, rank, '/bundle', 'a' * 64, [])
                                        arguments = config['arguments']
                                        self.assertEqual(arguments.count('--ffn-output-precision'), 1)
                                        self.assertEqual(arguments[arguments.index('--ffn-output-precision') + 1], 'float32')
                                        record = make_report(spec, rank)
                                        self.assertEqual(record['schemaVersion'], 9)
                                        reports.validate_report(record, spec, rank)
                                        if backend == 'replicas':
                                            continue
                                        _, ready = ready_fixture(spec, rank)
                                        protocol.ready(ready, EPOCH, rank, spec)
                                        self.assertEqual(ready['version'], 5)
                                        self.assertEqual(ready['identity']['ffnOutputPrecision'], 'float32')
                                        with tempfile.TemporaryDirectory() as directory:
                                            p = Path(directory) / 'rank.json'; p.write_text(json.dumps(config))
                                            configure(dict(local=directory, host=None), spec, EPOCH)
                                            worker = json.loads(p.read_text())['arguments']
                                            self.assertEqual(worker.count('--ffn-output-precision'), 1)
                                            self.assertEqual(worker[worker.index('--ffn-output-precision') + 1], 'float32')

    def test_invalid_precision_and_mutually_exclusive_family_policies_fail_locally(self):
        for synthetic in (True, False):
            for value in (None, True, False, 0, 32, 1.0, [], {}, '', 'Float32', 'bf16', 'float32 ', 'float32-through-norm'):
                with self.subTest(synthetic=synthetic, value=value), self.assertRaisesRegex(ValueError, 'precision'):
                    make_spec(synthetic=synthetic, ffn_output_precision=value)
        for branch in ('float32', 'float32-through-norm'):
            with self.subTest(branch=branch), self.assertRaisesRegex(ValueError, 'cannot be combined'):
                make_spec(synthetic=False, ffn_branch_precision=branch, ffn_output_precision='float32')

    def test_sparse_and_gemma_profiles_are_rejected_before_staging_or_process_creation(self):
        for profile in ('qwen-moe', 'gemma-moe', 'gemma-moe-w8'):
            with self.subTest(profile=profile):
                fixture = PersistentFixture(); self.addCleanup(fixture.cleanup)
                spec = cohort_spec()
                spec['workload'].update(synthetic_profile=profile, ffn_output_precision='float32')
                with self.assertRaisesRegex(ValueError, 'dense Qwen'):
                    PersistentCohort(copy.deepcopy(spec), fixture.source, fixture.output)
                specfile = fixture.root / 'spec.json'; specfile.write_text(json.dumps(spec))
                result = subprocess.run([sys.executable, str(Path(__file__).parent / 'run_inference.py'),
                    '--spec', str(specfile), '--bundle', str(fixture.source), '--output', str(fixture.output)],
                    capture_output=True, text=True, timeout=5)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('dense Qwen', result.stderr)
                self.assertFalse(fixture.output.exists())
                self.assertEqual(fixture.process_ids(), [])

    def test_real_report_and_ready_require_dense_qwen_for_float32(self):
        for backend in ('solo', 'jaccl'):
            for path in ('ordinary', 'cbv2-contiguous'):
                spec = make_spec(backend, synthetic=False, execution_path=path, ffn_output_precision='float32')
                for rank in range(len(spec['ranks'])):
                    good = make_report(spec, rank); reports.validate_report(good, spec, rank)
                    _, ready = ready_fixture(spec, rank); protocol.ready(ready, EPOCH, rank, spec)
                    for family, kind in (('qwen35', 'moe'), ('gemma4', 'moe'), ('gemma4', 'dense')):
                        with self.subTest(backend=backend, path=path, rank=rank, family=family, kind=kind):
                            record = copy.deepcopy(good); record.update(modelFamily=family, feedForwardKind=kind)
                            with self.assertRaisesRegex(ValueError, 'dense Qwen'):
                                reports.validate_report(record, spec, rank)
                            bad = copy.deepcopy(ready); bad['identity'].update(modelFamily=family, feedForwardKind=kind)
                            bad['identitySHA256'] = protocol.hash_frame(bad['identity'])
                            with self.assertRaisesRegex(PersistentCohortError, 'dense Qwen'):
                                protocol.ready(bad, EPOCH, rank, spec)

    def test_native_remains_available_to_qwen_moe_and_gemma(self):
        for profile in ('qwen-moe', 'gemma-moe', 'gemma-moe-w8'):
            branches = ('native', 'float32', 'float32-through-norm') if profile.startswith('gemma') else ('native',)
            for branch in branches:
                spec = make_spec('loopback-test', synthetic_profile=profile, ffn_branch_precision=branch)
                for rank in (0, 1):
                    reports.validate_report(make_report(spec, rank), spec, rank)
                    _, ready = ready_fixture(spec, rank); protocol.ready(ready, EPOCH, rank, spec)

    def test_missing_malformed_or_mismatched_policy_cannot_be_accepted(self):
        for requested in ('native', 'float32'):
            spec = make_spec('loopback-test', ffn_output_precision=requested)
            other = 'native' if requested == 'float32' else 'float32'
            for value in (None, True, [], {}, 'float16', other):
                record = make_report(spec); record['ffnOutputPrecision'] = value
                with self.assertRaisesRegex(ValueError, 'ffnOutputPrecision'):
                    reports.validate_report(record, spec, 0)
                _, ready = ready_fixture(spec); ready['identity']['ffnOutputPrecision'] = value
                ready['identitySHA256'] = protocol.hash_frame(ready['identity'])
                with self.assertRaisesRegex(PersistentCohortError, 'ffnOutputPrecision'):
                    protocol.ready(ready, EPOCH, 0, spec)
            record = make_report(spec); del record['ffnOutputPrecision']
            with self.assertRaises(ValueError): reports.validate_report(record, spec, 0)
            _, ready = ready_fixture(spec); del ready['identity']['ffnOutputPrecision']
            ready['identitySHA256'] = protocol.hash_frame(ready['identity'])
            with self.assertRaises(PersistentCohortError): protocol.ready(ready, EPOCH, 0, spec)

    def test_policy_is_part_of_shared_identity_and_mixed_cohorts_fail(self):
        specs = [make_spec('loopback-test', ffn_output_precision=precision) for precision in ('native', 'float32')]
        identities = []
        for spec in specs:
            peers = [ready_fixture(spec, rank)[1] for rank in (0, 1)]
            self.assertEqual(peers[0]['identitySHA256'], peers[1]['identitySHA256'])
            identities.append(peers[0]['identitySHA256'])
        self.assertNotEqual(*identities)
        with tempfile.TemporaryDirectory() as directory:
            ranks = []
            for rank, spec in enumerate(specs):
                record = make_report(spec, rank); reports.validate_report(record, spec, rank)
                path = Path(directory) / str(rank); path.mkdir()
                (path / 'stdout.jsonl').write_text(json.dumps(record) + '\n')
                ranks.append(dict(rank=rank, local=str(path)))
            with self.assertRaisesRegex(ValueError, 'ffnOutputPrecision'):
                reports.reports(ranks, specs[0])

    def test_old_schemas_and_protocols_remain_rejected_with_new_field(self):
        spec, ready = ready_fixture(make_spec(ffn_output_precision='float32'))
        for version in range(1, 9):
            record = make_report(spec); record['schemaVersion'] = version
            with self.assertRaises(ValueError): reports.validate_report(record, spec, 0)
        for kind in protocol.FRAME_KEYS:
            for version in (1, 2, 3, 4, 6, True, None):
                frame = {key: 'unused' for key in protocol.FRAME_KEYS[kind]}
                frame.update(version=version, type=kind, epoch=EPOCH, rank=0)
                with self.subTest(kind=kind, version=version), self.assertRaises(PersistentCohortError):
                    protocol.frame(frame, kind, EPOCH, 0)


class FFNOutputPrecisionLifecycleTests(unittest.TestCase):
    def test_wrong_or_missing_policy_fences_before_request_and_reaps_owned_processes(self):
        for precision in ('native', 'float32'):
            for fault in ('wrong_ffn_output_precision', 'missing_ffn_output_precision'):
                with self.subTest(precision=precision, fault=fault):
                    fixture = PersistentFixture({'1': fault}); self.addCleanup(fixture.cleanup)
                    spec = cohort_spec(); spec['workload']['ffn_output_precision'] = precision
                    cohort = PersistentCohort(spec, fixture.source, fixture.output); self.addCleanup(cohort.close)
                    with self.assertRaises(PersistentCohortError): cohort.start()
                    fixture.assert_stopped()
                    self.assertEqual(cohort.state, 'failed'); self.assertIsNone(cohort.epoch)
                    with self.assertRaises(PersistentCohortError): cohort.infer('no-reuse', [3], 1, 1)
                    for rank in (0, 1): self.assertFalse(any(e['event'] == 'infer' for e in fixture.events(rank)))

    def test_float32_policy_survives_persistent_reuse_on_both_execution_paths(self):
        for path in ('ordinary', 'cbv2-contiguous'):
            for partition in ('ffn', 'full'):
                with self.subTest(path=path, partition=partition):
                    fixture = PersistentFixture(); self.addCleanup(fixture.cleanup)
                    spec = cohort_spec(); spec['partition'] = partition
                    spec['workload'].update(execution_path=path, ffn_output_precision='float32')
                    with PersistentCohort(spec, fixture.source, fixture.output) as cohort:
                        epoch, pids = cohort.epoch, cohort.workerPIDs
                        self.assertTrue(all(r['version'] == 5 and r['identity']['ffnOutputPrecision'] == 'float32'
                                            for r in cohort.ready))
                        a = cohort.infer('a-first', [3, 5], 2, 2, capture_logits=True)
                        cohort.infer('b', [8, 11, 13], 2, 2, capture_logits=True)
                        last = cohort.infer('a-last', [3, 5], 2, 2, capture_logits=True)
                        self.assertEqual(cohort.epoch, epoch); self.assertEqual(cohort.workerPIDs, pids)
                        for rank in (0, 1):
                            self.assertEqual(a[rank]['logits'], last[rank]['logits'])
                            self.assertEqual(a[rank]['modelLoadID'], last[rank]['modelLoadID'])
                            loaded = [e for e in fixture.events(rank) if e['event'] == 'loaded']
                            self.assertEqual(len(loaded), 1)
                            self.assertEqual(loaded[0]['ffn_output_precision'], 'float32')
                    fixture.assert_stopped()
                    self.assertEqual(cohort.state, 'closed'); self.assertIsNone(cohort.epoch)


if __name__ == '__main__':
    unittest.main()
