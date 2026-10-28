"""Fabricated subprocess peers/callbacks only; no native/model qualification."""

import ast
import copy
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
import uuid

from worker_adapter import ResidentWorkerCohort
from worker_contract import WorkerSpec, SUFFIXES
import worker_processes


class AdapterTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.output = Path(self.temp.name) / 'output'
        self.declared = [dict(request_id='prompt:condition' + suffix, epoch='%032x' % (index + 1))
                         for index, suffix in enumerate(SUFFIXES)]
        self.requests = [dict(request_id=row['request_id'], phase='warmup' if index == 0 else 'measured',
                              iteration=0 if index == 0 else index - 1) for index, row in enumerate(self.declared)]
        self.gates, self.identities, self.numeric = [], [], []

    def spec(self, mode='success', rank=None):
        return WorkerSpec((sys.executable, '-B', '-u', str(Path(__file__).with_name('fake_worker.py')),
                           mode, 'solo' if rank is None else 'rank', 'none' if rank is None else str(rank)),
                          {'PYTHONDONTWRITEBYTECODE': '1'}, 'solo' if rank is None else 'rank', rank)

    def identity(self, spec, event, command):
        self.identities.append((event['type'], spec.rank))
        if event['type'] == 'result':
            step = event['record']['step']
            self.assertEqual(step['requestID'], str(uuid.UUID(command['epoch'])))
            self.assertEqual(step['ordinal'], command['sequence'] - 1)
            self.assertEqual(step['excludedWarmup'], command['sequence'] == 1)

    def numerical(self, command, results):
        self.numeric.append(command['sequence'])
        self.assertTrue(all(row['record']['execution']['selection'] == 1 for row in results))
        return dict(elapsed_ns=1000000000, prompt_tokens=8192, generated_tokens=1, source_sha256='c' * 64)

    def cohort(self, specs=None, **kwargs):
        values = dict(workers=specs or [self.spec()], cohort_id='prompt:condition', requests=self.declared,
                      output_directory=self.output, timeout_seconds=5, resource_gate=self.gates.append,
                      identity_validator=self.identity, numerical_validator=self.numerical)
        values.update(kwargs)
        return ResidentWorkerCohort(**values)

    def assert_reaped(self, cohort):
        self.assertTrue(cohort._pipes.closed)
        self.assertTrue(all(child.poll() is not None for child in cohort._pipes.children))

    def test_solo_and_rank_success_retains_exact_commands_and_private_modes(self):
        for count in (1, 2):
            self.output = Path(self.temp.name) / ('success%d' % count)
            cohort = self.cohort([self.spec()] if count == 1 else [self.spec(rank=0), self.spec(rank=1)])
            with cohort:
                for request in self.requests:
                    self.assertEqual(cohort.run(request)['elapsed_ns'], 1000000000)
            self.assert_reaped(cohort)
            evidence = cohort.evidence()
            self.assertTrue(evidence['output_complete'] and evidence['stopped'])
            self.assertFalse(evidence['failed'] or evidence['runtime_admission'] or evidence['performance_qualification'])
            for index in range(count):
                commands = [json.loads(line) for line in (self.output / ('worker-%d.stdin' % index)).read_bytes().splitlines()]
                self.assertEqual([row['type'] for row in commands], ['open'] + ['run'] * 4 + ['shutdown'])
                self.assertEqual([row.get('sequence') for row in commands], [None, 1, 2, 3, 4, 5])
            for row in evidence['streams']:
                self.assertEqual(stat.S_IMODE(Path(row['path']).stat().st_mode), 0o600)
            self.assertEqual(stat.S_IMODE(self.output.stat().st_mode), 0o700)
        self.assertIn('prelaunch', self.gates)
        self.assertIn('before-request-3', self.gates)

    def test_failed_enter_cleanup_for_bad_event_exit_and_partial_spawn(self):
        for mode in ('wrong-role', 'duplicate-key', 'exit-enter', 'stderr'):
            self.output = Path(self.temp.name) / mode
            cohort = self.cohort([self.spec(mode, 0), self.spec('hang-open', 1)])
            with self.assertRaises(ValueError):
                cohort.__enter__()
            self.assert_reaped(cohort)
            self.assertFalse(cohort.evidence()['output_complete'])
        self.output = Path(self.temp.name) / 'spawn-failure'
        missing = WorkerSpec(('/definitely/missing/fake-peer',), {}, 'rank', 1)
        cohort = self.cohort([self.spec('hang-open', 0), missing])
        with self.assertRaises(OSError):
            cohort.__enter__()
        self.assert_reaped(cohort)

    def test_timeout_reaps_both_groups(self):
        cohort = self.cohort([self.spec('hang-open', 0), self.spec('hang-open', 1)], timeout_seconds=1)
        start = time.monotonic()
        with self.assertRaises(TimeoutError):
            cohort.__enter__()
        self.assertLess(time.monotonic() - start, 3)
        self.assert_reaped(cohort)

    def test_request_replay_wrong_command_incomplete_output_and_early_close(self):
        for mode in ('wrong-command', 'incomplete', 'null-resources'):
            self.output = Path(self.temp.name) / mode
            cohort = self.cohort([self.spec(mode)])
            with self.assertRaises(ValueError):
                with cohort:
                    cohort.run(self.requests[0])
            self.assert_reaped(cohort)
        self.output = Path(self.temp.name) / 'replay'
        cohort = self.cohort()
        with self.assertRaises(ValueError):
            with cohort:
                cohort.run(self.requests[0]); cohort.run(self.requests[0])
        commands = (self.output / 'worker-0.stdin').read_text().splitlines()
        self.assertEqual(len(commands), 2)
        self.assert_reaped(cohort)
        self.output = Path(self.temp.name) / 'early-close'
        cohort = self.cohort()
        with self.assertRaises(ValueError):
            with cohort:
                pass
        self.assert_reaped(cohort)

    def test_required_validators_and_gate_failures_stop_before_next_command(self):
        for key in ('resource_gate', 'identity_validator', 'numerical_validator'):
            with self.assertRaises(ValueError):
                self.cohort(**{key: None})
        self.assertFalse(self.output.exists())
        def fail(*args):
            raise LookupError('invented callback failure')
        for key in ('resource_gate', 'identity_validator', 'numerical_validator'):
            self.output = Path(self.temp.name) / key
            cohort = self.cohort(**{key: fail})
            with self.assertRaises(LookupError):
                with cohort:
                    cohort.run(self.requests[0])
            self.assert_reaped(cohort)
            if self.output.exists():
                commands = (self.output / 'worker-0.stdin').read_text().splitlines()
                self.assertLessEqual(len(commands), 2)

    def test_output_caps_retain_bounded_prefix_and_exclusive_directory(self):
        for limit, value in (('MAX_LINE', 1024), ('MAX_OUTPUT', 1024)):
            self.output = Path(self.temp.name) / limit
            cohort = self.cohort([self.spec('large')])
            with patch.object(worker_processes, limit, value):
                with self.assertRaises(ValueError):
                    with cohort:
                        cohort.run(self.requests[0])
            self.assert_reaped(cohort)
            self.assertFalse(cohort.evidence()['output_complete'])
            if limit == 'MAX_OUTPUT':
                self.assertLessEqual(sum(row['bytes'] for row in cohort.evidence()['streams'] if row['stream'] != 'stdin'), value)
        self.output = Path(self.temp.name) / 'existing'
        self.output.mkdir(); marker = self.output / 'marker'; marker.write_bytes(b'unchanged')
        with self.assertRaises(FileExistsError):
            self.cohort().__enter__()
        self.assertEqual(marker.read_bytes(), b'unchanged')

    def test_release_stopped_eof_and_zero_exit_all_required(self):
        for mode in ('missing-release', 'trailing', 'nonzero-exit'):
            self.output = Path(self.temp.name) / mode
            cohort = self.cohort([self.spec(mode)])
            with self.assertRaises(ValueError):
                with cohort:
                    for request in self.requests:
                        cohort.run(request)
            self.assert_reaped(cohort)
            self.assertFalse(cohort.evidence()['output_complete'])

    def test_slow_callback_still_expires_process_groups(self):
        def slow(command, results):
            time.sleep(1.1)
            self.assertTrue(all(child.poll() is not None for child in cohort._pipes.children))
            return {}
        cohort = self.cohort(timeout_seconds=1, numerical_validator=slow)
        with self.assertRaises(TimeoutError):
            with cohort:
                cohort.run(self.requests[0])
        self.assert_reaped(cohort)

    def test_swallowed_reentrant_error_cannot_publish_success(self):
        def reenter(command, results):
            try:
                cohort.run(self.requests[0])
            except ValueError:
                pass
            return {}
        cohort = self.cohort(numerical_validator=reenter)
        with self.assertRaises(ValueError):
            with cohort:
                cohort.run(self.requests[0])
        self.assertEqual(cohort._ordinal, 0)
        self.assert_reaped(cohort)

    def test_keyboard_interrupt_propagates_after_cleanup(self):
        cohort = self.cohort()
        with self.assertRaises(KeyboardInterrupt):
            with cohort:
                raise KeyboardInterrupt()
        self.assert_reaped(cohort)

    def test_eager_result_before_run_is_refused_without_measurement(self):
        cohort = self.cohort([self.spec('early-result')])
        with self.assertRaisesRegex(ValueError, 'Unsolicited'):
            with cohort:
                # Allow the fake's deliberately eager second line to reach the
                # pipe; no run command has yet been sent.
                time.sleep(0.02)
                cohort.run(self.requests[0])
        self.assertEqual(self.numeric, [])
        self.assertEqual(len((self.output / 'worker-0.stdin').read_bytes().splitlines()), 1)
        self.assert_reaped(cohort)

    def test_every_command_fully_written_before_any_event_validator(self):
        original_write = os.write
        def short_write(fd, raw):
            return original_write(fd, raw[:13])
        def inspect(spec, value, command):
            for index in (0, 1):
                raw = (self.output / ('worker-%d.stdin' % index)).read_bytes()
                self.assertTrue(raw.endswith(b'\n'))
                self.assertEqual(json.loads(raw.splitlines()[-1]), command)
            self.identity(spec, value, command)
        cohort = self.cohort([self.spec(rank=0), self.spec(rank=1)], identity_validator=inspect)
        with patch.object(worker_processes.os, 'write', short_write):
            with cohort:
                for request in self.requests:
                    cohort.run(request)
        self.assert_reaped(cohort)

    def test_callback_boolean_returns_are_not_success(self):
        for key in ('resource_gate', 'identity_validator'):
            self.output = Path(self.temp.name) / key
            cohort = self.cohort(**{key: lambda *args: False})
            with self.assertRaises(ValueError):
                cohort.__enter__()
            self.assert_reaped(cohort)

    def test_cleanup_interrupt_is_preserved_after_all_workers_reaped(self):
        original_wait = subprocess.Popen.wait
        for interrupt in (KeyboardInterrupt(), SystemExit(9)):
            self.output = Path(self.temp.name) / type(interrupt).__name__
            cohort = self.cohort([self.spec(rank=0), self.spec(rank=1)])
            cohort.__enter__()
            raised = []
            def interrupted_wait(child, *args, **kwargs):
                if not raised:
                    raised.append(True)
                    raise interrupt
                return original_wait(child, *args, **kwargs)
            with patch.object(subprocess.Popen, 'wait', interrupted_wait):
                with self.assertRaises(type(interrupt)):
                    cohort.close()  # Early close must clean up, then preserve interruption.
            self.assert_reaped(cohort)
            self.assertTrue(all(handle.closed for handle in cohort._pipes.logs.values()))

    def test_metadata_detachment_and_python39_syntax(self):
        def mutate(spec, value, command):
            spec.env['annotation'] = 'only-copy'; value['cohort_id'] = 'changed'; command.clear()
        cohort = self.cohort(identity_validator=mutate)
        before = copy.deepcopy(self.declared)
        with cohort:
            for request in self.requests:
                cohort.run(request)
        self.assertEqual(self.declared, before)
        self.assertNotIn('annotation', cohort._specs[0].env)
        for name in ('worker_contract.py', 'worker_processes.py', 'worker_adapter.py', 'fake_worker.py', 'test_worker_adapter.py'):
            ast.parse(Path(__file__).with_name(name).read_text(), feature_version=(3, 9))


if __name__ == '__main__':
    unittest.main()
