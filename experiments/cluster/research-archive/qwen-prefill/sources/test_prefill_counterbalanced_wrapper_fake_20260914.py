#!/usr/bin/env python3
"""Independent fake-only cancellation/partial-study checks; never starts a job."""
from contextlib import ExitStack, redirect_stdout
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent
WRAPPER = ROOT / 'run-prefill-counterbalanced-study-20260914.py'
WRAPPER_SHA = 'bde0da6a670fe380345f6f230b26b88412c247f1d6d4c6c4225d444f8a1c2763'
if hashlib.sha256(WRAPPER.read_bytes()).hexdigest() != WRAPPER_SHA:
    raise ValueError('Frozen study wrapper differs')
spec = importlib.util.spec_from_file_location('fake_only_study_wrapper', WRAPPER)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class FakeChild:
    pid = 424242

    def __init__(self, outcomes):
        self.outcomes = iter(outcomes)
        self.returncode = None
        self.waits = []

    def wait(self, timeout):
        self.waits.append(timeout)
        result = next(self.outcomes)
        if isinstance(result, BaseException):
            raise result
        self.returncode = result
        return result

    def poll(self):
        return self.returncode


class WrapperChecks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='prefill-study-cpu-fake-')
        self.path = Path(self.temp.name)
        m.CHILD = None
        m.COMMAND_CLEANUP_ERRORS.clear()

    def tearDown(self):
        self.temp.cleanup()

    def fake_command(self, outcomes, error=None, signal_error=None):
        child = FakeChild(outcomes)
        with patch.object(m.subprocess, 'Popen', return_value=child) as popen, \
             patch.object(m.os, 'killpg', side_effect=signal_error) as kill:
            if error:
                with self.assertRaises(error) as caught:
                    m.command(['never-executed'], self.path / 'command.log', 9)
            else:
                m.command(['never-executed'], self.path / 'command.log', 9)
                caught = None
            self.assertTrue(popen.call_args.kwargs['start_new_session'])
            return child, kill.call_args_list, caught

    def test_success_reaps_and_releases_handle(self):
        child, calls, _ = self.fake_command([0])
        self.assertEqual(child.waits, [9])
        self.assertEqual(calls, [])
        self.assertIsNone(m.CHILD)

    def test_nonzero_preserves_failure_without_signalling_dead_child(self):
        child, calls, caught = self.fake_command([7], RuntimeError)
        self.assertIn('exit 7', str(caught.exception))
        self.assertEqual(calls, [])
        self.assertIsNone(m.CHILD)
        self.assertIn('Root command error: RuntimeError:', (self.path / 'command.log').read_text())

    def test_timeout_terms_owned_group_then_preserves_primary(self):
        primary = subprocess.TimeoutExpired('fake', 9)
        child, calls, caught = self.fake_command([primary, -15], subprocess.TimeoutExpired)
        self.assertIs(caught.exception, primary)
        self.assertEqual(child.waits, [9, 45])
        self.assertEqual([c.args for c in calls], [(child.pid, signal.SIGTERM)])
        self.assertEqual(m.COMMAND_CLEANUP_ERRORS, [])
        self.assertIsNone(m.CHILD)

    def test_escalation_records_cleanup_and_preserves_primary(self):
        primary = subprocess.TimeoutExpired('fake', 9)
        child, calls, caught = self.fake_command(
            [primary, subprocess.TimeoutExpired('fake', 45), -9], subprocess.TimeoutExpired)
        self.assertIs(caught.exception, primary)
        self.assertEqual(child.waits, [9, 45, 5])
        self.assertEqual([c.args for c in calls], [(child.pid, signal.SIGTERM), (child.pid, signal.SIGKILL)])
        self.assertEqual(len(m.COMMAND_CLEANUP_ERRORS), 1)
        self.assertIn('remote cleanup needs inspection', m.COMMAND_CLEANUP_ERRORS[0])
        self.assertIsNone(m.CHILD)

    def test_cleanup_error_preserves_primary_and_live_handle(self):
        primary = subprocess.TimeoutExpired('fake', 9)
        child, calls, caught = self.fake_command([primary], subprocess.TimeoutExpired, PermissionError('fake'))
        self.assertIs(caught.exception, primary)
        self.assertIs(m.CHILD, child)
        self.assertEqual(m.COMMAND_CLEANUP_ERRORS, ['PermissionError: fake'])

    def main_fixture(self, fail_at=None):
        plan = {'trials': [{'index': n} for n in range(1, 15)], 'replacementPointsAllowed': False}
        plan_path = self.path / 'fake-plan.json'
        plan_path.write_text(json.dumps(plan))
        out = self.path / 'fake-study'
        visited = []
        def trial(_plan, item, _oracle):
            visited.append(item['index'])
            (out / ('fake-trial-%02d.log' % item['index'])).write_text('retained fake evidence')
            if item['index'] == fail_at:
                raise ValueError('fake audit failure')
            return dict(item)
        with ExitStack() as stack:
            stack.enter_context(patch.object(m, 'PLAN', plan_path))
            stack.enter_context(patch.object(m, 'OUT', out))
            stack.enter_context(patch.object(m, 'verify_pins', return_value=None))
            stack.enter_context(patch.object(m, 'load_oracle', return_value=object()))
            stack.enter_context(patch.object(m, 'trial', side_effect=trial))
            stack.enter_context(patch.object(m.signal, 'signal', return_value=None))
            stack.enter_context(patch.object(m.sys, 'argv', ['fake', m.sha(plan_path)]))
            stack.enter_context(patch.object(m.subprocess, 'Popen', side_effect=AssertionError('Real Popen forbidden')))
            stack.enter_context(patch.object(m.os, 'killpg', side_effect=AssertionError('Real killpg forbidden')))
            stack.enter_context(redirect_stdout(io.StringIO()))
            code = m.main()
        return out, visited, code, json.loads((out / 'study-receipt.json').read_text())

    def test_failed_trial_stops_and_retains_failed_partial(self):
        out, visited, code, receipt = self.main_fixture(fail_at=4)
        self.assertEqual(code, 1)
        self.assertEqual(visited, [1, 2, 3, 4])
        self.assertEqual([x['index'] for x in receipt['completedTrials']], [1, 2, 3])
        self.assertFalse(receipt['passed'])
        self.assertEqual(receipt['error'], 'ValueError: fake audit failure')
        self.assertEqual((out / 'fake-trial-04.log').read_text(), 'retained fake evidence')
        self.assertFalse((out / 'fake-trial-05.log').exists())

    def test_fourteen_fixed_trials_complete_without_qualification(self):
        out, visited, code, receipt = self.main_fixture()
        self.assertEqual(code, 0)
        self.assertEqual(visited, list(range(1, 15)))
        self.assertEqual(len(receipt['completedTrials']), 14)
        self.assertTrue(receipt['passed'])
        for key in ('throughputQualified', 'physicalTwoMachineExecution', 'residentWarmthQualified'):
            self.assertFalse(receipt[key])

    def test_existing_output_preserved_before_any_trial(self):
        out, _, _, _ = self.main_fixture(fail_at=1)
        before = (out / 'study-receipt.json').read_bytes()
        plan = self.path / 'fake-plan.json'
        with patch.object(m, 'PLAN', plan), patch.object(m, 'OUT', out), \
             patch.object(m, 'verify_pins', return_value=None), \
             patch.object(m.sys, 'argv', ['fake', m.sha(plan)]), \
             patch.object(m, 'trial', side_effect=AssertionError('Trial forbidden')):
            with self.assertRaisesRegex(AssertionError, 'Preserve previous'):
                m.main()
        self.assertEqual((out / 'study-receipt.json').read_bytes(), before)


if __name__ == '__main__':
    unittest.main(verbosity=2)
