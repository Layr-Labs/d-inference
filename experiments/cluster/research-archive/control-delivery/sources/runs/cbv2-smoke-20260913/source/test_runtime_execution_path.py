"""Execution-path admission and identity; subprocess fixtures do not test CBv2 math."""

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest

from persistent_test_support import PersistentFixture, cohort_spec
from runtime import configuration, reports
from runtime import persistent_protocol as protocol
from runtime.persistent import PersistentCohort, PersistentCohortError
from runtime.persistent_processes import configure
from test_persistent_protocol import EPOCH, ready_fixture
from test_runtime_contract import run_spec
from test_runtime_reports import make_report, make_spec


PATHS = ('ordinary', 'cbv2-contiguous')
PROFILES = ('tiny', 'qwen9-heads', 'qwen27-heads')


class ExecutionPathTests(unittest.TestCase):
    def test_ordinary_default_is_explicit_even_for_real_models(self):
        for synthetic in (False, True):
            raw = run_spec(synthetic=synthetic)
            self.assertNotIn('execution_path', raw['workload'])
            spec = configuration.validate(raw)
            self.assertEqual(spec['workload']['execution_path'], 'ordinary')
            args = configuration.rank_configuration(spec, 0, '/bundle', 'a' * 64, [])['arguments']
            self.assertEqual(args.count('--execution-path'), 1)
            self.assertEqual(args[args.index('--execution-path') + 1], 'ordinary')

    def test_cbv2_dense_profiles_preserve_path_across_each_rank_and_worker(self):
        for backend in ('solo', 'replicas', 'jaccl', 'loopback-test'):
            partitions = ('ffn', 'full') if backend in ('jaccl', 'loopback-test') else ('ffn',)
            for partition in partitions:
                for profile in PROFILES:
                    for dtype in ('float32', 'bfloat16'):
                        spec = make_spec(backend, partition=partition, synthetic_profile=profile,
                                         synthetic_dtype=dtype, execution_path='cbv2-contiguous')
                        for rank in range(len(spec['ranks'])):
                            with self.subTest(backend=backend, partition=partition, profile=profile, dtype=dtype, rank=rank):
                                config = configuration.rank_configuration(spec, rank, '/bundle', 'a' * 64, [])
                                args = config['arguments']
                                self.assertEqual(args.count('--execution-path'), 1)
                                self.assertEqual(args[args.index('--execution-path') + 1], 'cbv2-contiguous')
                                record = make_report(spec, rank)
                                reports.validate_report(record, spec, rank)
                                self.assertEqual(record['schemaVersion'], 8)
                                if backend == 'replicas':
                                    continue
                                with tempfile.TemporaryDirectory() as temporary:
                                    path = Path(temporary) / 'rank.json'
                                    path.write_text(json.dumps(config))
                                    configure(dict(local=temporary, host=None), spec, EPOCH)
                                    worker_args = json.loads(path.read_text())['arguments']
                                    self.assertEqual(worker_args.count('--execution-path'), 1)
                                    self.assertEqual(worker_args[worker_args.index('--execution-path') + 1], 'cbv2-contiguous')
                                _, ready = ready_fixture(spec, rank)
                                protocol.ready(ready, EPOCH, rank, spec)
                                self.assertEqual(ready['identity']['executionPath'], 'cbv2-contiguous')

    def test_bad_path_types_names_and_gemma_only_precision_are_rejected(self):
        for synthetic in (False, True):
            for value in (None, True, False, 0, 1.0, [], {}, '', 'CBv2', 'cbv2', 'ordinary ', 'cbv2-contiguous '):
                with self.subTest(synthetic=synthetic, value=value), self.assertRaises(ValueError):
                    make_spec(synthetic=synthetic, execution_path=value)
        for precision in ('float32', 'float32-through-norm'):
            with self.assertRaises(ValueError):
                make_spec(synthetic=False, execution_path='cbv2-contiguous', ffn_branch_precision=precision)

    def test_unsupported_synthetic_families_fail_before_process_or_output_creation(self):
        for profile in ('qwen-moe', 'gemma-moe', 'gemma-moe-w8'):
            with self.subTest(profile=profile):
                fixture = PersistentFixture()
                self.addCleanup(fixture.cleanup)
                spec = cohort_spec()
                spec['workload'].update(synthetic_profile=profile, execution_path='cbv2-contiguous')
                with self.assertRaisesRegex(ValueError, 'dense Qwen'):
                    PersistentCohort(spec, fixture.source, fixture.output)
                spec_path = fixture.root / 'spec.json'
                spec_path.write_text(json.dumps(spec))
                result = subprocess.run([sys.executable, str(Path(__file__).parent / 'run_inference.py'),
                    '--spec', str(spec_path), '--bundle', str(fixture.source), '--output', str(fixture.output)],
                    capture_output=True, text=True, timeout=5)
                self.assertEqual(result.returncode, 2)
                self.assertIn('dense Qwen', result.stderr)
                self.assertFalse(fixture.output.exists())
                self.assertEqual(fixture.process_ids(), [])
                # Their existing ordinary path remains admitted.
                spec['workload']['execution_path'] = 'ordinary'
                configuration.validate(spec)

    def test_cbv2_admission_reserves_all_outputs_and_enforces_bounded_output(self):
        for synthetic in (False, True):
            for prompt, output, accepted in ((32767, 1, True), (32768, 1, False),
                                             (28672, 4096, True), (28673, 4096, False),
                                             (1, 4097, False)):
                raw = run_spec(synthetic=synthetic)
                raw['workload'].update(execution_path='cbv2-contiguous', prompt_tokens=prompt, decode_tokens=output)
                with self.subTest(synthetic=synthetic, prompt=prompt, output=output):
                    if accepted:
                        configuration.validate(raw)
                    else:
                        with self.assertRaisesRegex(ValueError, '32768'):
                            configuration.validate(raw)
                    raw['workload']['execution_path'] = 'ordinary'
                    configuration.validate(raw)

    def test_real_cbv2_reports_and_ready_require_dense_qwen_identity(self):
        for backend in ('solo', 'jaccl'):
            spec = make_spec(backend, synthetic=False, execution_path='cbv2-contiguous')
            for family, kind in (('qwen35', 'dense'), ('qwen35', 'moe'), ('gemma4', 'dense'), ('gemma4', 'moe')):
                for rank in range(len(spec['ranks'])):
                    record = make_report(spec, rank)
                    record.update(modelFamily=family, feedForwardKind=kind)
                    _, ready = ready_fixture(spec, rank)
                    ready['identity'].update(modelFamily=family, feedForwardKind=kind)
                    ready['identitySHA256'] = protocol.hash_frame(ready['identity'])
                    with self.subTest(backend=backend, family=family, kind=kind, rank=rank):
                        if (family, kind) == ('qwen35', 'dense'):
                            reports.validate_report(record, spec, rank)
                            protocol.ready(ready, EPOCH, rank, spec)
                        else:
                            with self.assertRaisesRegex(ValueError, 'dense Qwen'):
                                reports.validate_report(record, spec, rank)
                            with self.assertRaisesRegex(PersistentCohortError, 'dense Qwen'):
                                protocol.ready(ready, EPOCH, rank, spec)

    def test_missing_malformed_or_mismatched_path_cannot_be_accepted(self):
        for requested in PATHS:
            spec = make_spec('loopback-test', execution_path=requested)
            other = next(path for path in PATHS if path != requested)
            for value in (None, True, [], {}, 'unknown', other):
                record = make_report(spec); record['executionPath'] = value
                with self.assertRaisesRegex(ValueError, 'executionPath'):
                    reports.validate_report(record, spec, 0)
                _, ready = ready_fixture(spec); ready['identity']['executionPath'] = value
                ready['identitySHA256'] = protocol.hash_frame(ready['identity'])
                with self.assertRaisesRegex(PersistentCohortError, 'executionPath'):
                    protocol.ready(ready, EPOCH, 0, spec)
            record = make_report(spec); del record['executionPath']
            with self.assertRaises(ValueError): reports.validate_report(record, spec, 0)
            _, ready = ready_fixture(spec); del ready['identity']['executionPath']
            ready['identitySHA256'] = protocol.hash_frame(ready['identity'])
            with self.assertRaises(PersistentCohortError): protocol.ready(ready, EPOCH, 0, spec)

    def test_path_is_part_of_common_identity_and_mixed_reports_fail(self):
        specs = [make_spec('loopback-test', execution_path=path) for path in PATHS]
        identities = []
        for spec in specs:
            peers = [ready_fixture(spec, rank)[1] for rank in range(2)]
            self.assertEqual(peers[0]['identitySHA256'], peers[1]['identitySHA256'])
            identities.append(peers[0]['identitySHA256'])
        self.assertNotEqual(*identities)
        records = [make_report(specs[rank], rank) for rank in range(2)]
        with tempfile.TemporaryDirectory() as temporary:
            ranks = []
            for rank, record in enumerate(records):
                reports.validate_report(record, specs[rank], rank)
                path = Path(temporary) / str(rank); path.mkdir()
                (path / 'stdout.jsonl').write_text(json.dumps(record) + '\n')
                ranks.append(dict(rank=rank, local=str(path)))
            with self.assertRaisesRegex(ValueError, 'executionPath'):
                reports.reports(ranks, specs[0])

    def test_prior_report_and_every_prior_protocol_frame_version_are_rejected(self):
        spec, ready = ready_fixture(make_spec(execution_path='cbv2-contiguous'))
        record = make_report(spec); record['schemaVersion'] = 7
        with self.assertRaises(ValueError): reports.validate_report(record, spec, 0)
        command = protocol.request(EPOCH, 1, 'a', [1, 2], 2, 2, None, False, 5, ready)
        for kind in ('ready', 'accepted', 'token', 'completed', 'stopped'):
            for version in (1, 2, 3, 5, True, None):
                frame = {key: 'unused' for key in protocol.FRAME_KEYS[kind]}
                frame.update(version=version, type=kind, epoch=EPOCH, rank=0)
                with self.subTest(kind=kind, version=version), self.assertRaises(PersistentCohortError):
                    protocol.frame(frame, kind, EPOCH, 0)
        self.assertEqual(command['version'], 4)

    def test_protocol4_request_hash_matches_native_selfcheck_fixture(self):
        _, ready = ready_fixture()
        command = protocol.request('a' * 32, 1, 'check:1', [1, 2, 3], 3, 2,
                                   [4, 5], True, 30, ready)
        self.assertEqual(protocol.hash_frame(command),
                         '168a6c912b4c38f111ef02b46d86a512a4132c604cb8f1dcda94b452cb186cd3')


class ExecutionPathLifecycleTests(unittest.TestCase):
    def test_wrong_or_missing_path_retires_processes_before_any_request(self):
        for requested in PATHS:
            for fault in ('wrong_execution_path', 'missing_execution_path'):
                with self.subTest(path=requested, fault=fault):
                    fixture = PersistentFixture({'1': fault})
                    self.addCleanup(fixture.cleanup)
                    spec = cohort_spec(); spec['workload']['execution_path'] = requested
                    cohort = PersistentCohort(spec, fixture.source, fixture.output)
                    self.addCleanup(cohort.close)
                    with self.assertRaises(PersistentCohortError): cohort.start()
                    fixture.assert_stopped()
                    self.assertIsNone(cohort.epoch)
                    with self.assertRaises(PersistentCohortError): cohort.infer('no-reuse', [3], 1, 1)
                    for rank in (0, 1):
                        self.assertFalse(any(e['event'] == 'infer' for e in fixture.events(rank)))

    def test_cbv2_identity_survives_reuse_and_shutdown_for_both_partitions(self):
        for partition in ('ffn', 'full'):
            fixture = PersistentFixture(); self.addCleanup(fixture.cleanup)
            spec = cohort_spec(); spec['partition'] = partition
            spec['workload']['execution_path'] = 'cbv2-contiguous'
            with PersistentCohort(spec, fixture.source, fixture.output) as cohort:
                pids, epoch = cohort.workerPIDs, cohort.epoch
                self.assertTrue(all(r['version'] == 4 and r['identity']['executionPath'] == 'cbv2-contiguous'
                                    for r in cohort.ready))
                first = cohort.infer('A1', [3, 5], 2, 2)
                cohort.infer('B', [7, 9], 2, 2)
                repeated = cohort.infer('A2', [3, 5], 2, 2)
                self.assertEqual(cohort.workerPIDs, pids); self.assertEqual(cohort.epoch, epoch)
                self.assertEqual(first[0]['result']['generatedTokens'], repeated[0]['result']['generatedTokens'])
                for rank in (0, 1):
                    loaded = [e for e in fixture.events(rank) if e['event'] == 'loaded']
                    self.assertEqual(len(loaded), 1)
                    self.assertEqual(loaded[0]['execution_path'], 'cbv2-contiguous')
            fixture.assert_stopped()

    def test_cbv2_active_cancellation_fences_epoch_and_owned_processes(self):
        fixture = PersistentFixture({'0': 'hang_active', '1': 'hang_active'})
        self.addCleanup(fixture.cleanup)
        spec = cohort_spec(); spec['partition'] = 'full'; spec['workload']['execution_path'] = 'cbv2-contiguous'
        cohort = PersistentCohort(spec, fixture.source, fixture.output)
        self.addCleanup(cohort.close); cohort.start()
        errors = []
        def infer():
            try: cohort.infer('active', [3, 5], 2, 2, timeout_seconds=10)
            except BaseException as error: errors.append(error)
        thread = threading.Thread(target=infer, daemon=True); thread.start()
        fixture.wait_for_active('active'); cohort.cancel(); thread.join(4)
        self.assertFalse(thread.is_alive()); self.assertEqual(len(errors), 1)
        self.assertIsInstance(errors[0], PersistentCohortError)
        fixture.assert_stopped(); self.assertIsNone(cohort.epoch)
        with self.assertRaises(PersistentCohortError): cohort.infer('after-fence', [3], 1, 1)


if __name__ == '__main__':
    unittest.main()
