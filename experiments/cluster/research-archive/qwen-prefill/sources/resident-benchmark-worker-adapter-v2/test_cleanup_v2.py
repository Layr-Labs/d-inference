"""Focused teardown regressions with invented peers and injected OS failures."""

import io
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from worker_adapter import ResidentWorkerCohort
from worker_contract import SUFFIXES, WorkerSpec
from worker_processes import PipeWorkers


class UnprintableCleanupError(OSError):
    def __str__(self):
        raise RuntimeError('invented formatter failure')


class CleanupV2Tests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)

    def cohort(self, name):
        specs = [WorkerSpec((sys.executable, '-B', '-u', str(Path(__file__).with_name('fake_worker.py')),
                             'success', 'rank', str(rank)), {'PYTHONDONTWRITEBYTECODE': '1'}, 'rank', rank)
                 for rank in (0, 1)]
        requests = [dict(request_id='prompt:condition' + suffix, epoch='%032x' % (index + 1))
                    for index, suffix in enumerate(SUFFIXES)]
        return ResidentWorkerCohort(specs, 'prompt:condition', requests, Path(self.temp.name) / name, 5,
                                    lambda phase: None, lambda *args: None, lambda *args: {})

    def assert_closed(self, cohort):
        self.assertTrue(cohort._pipes.closed)
        self.assertTrue(all(child.poll() is not None for child in cohort._pipes.children))
        self.assertTrue(all(getattr(child, stream).closed for child in cohort._pipes.children
                            for stream in ('stdin', 'stdout', 'stderr')))
        self.assertTrue(all(handle.closed for handle in cohort._pipes.logs.values()))
        self.assertTrue(cohort._pipes.timer.finished.is_set())

    def test_initial_kill_interrupt_fences_other_group_before_reaping(self):
        original_kill, original_wait = os.killpg, subprocess.Popen.wait
        for interruption in (KeyboardInterrupt(), SystemExit(17)):
            cohort = self.cohort(type(interruption).__name__)
            cohort.__enter__()
            killed, injected = [], []
            def kill(pgid, sig):
                self.assertFalse(cohort._pipes.closed)
                self.assertFalse(cohort._pipes.timer.finished.is_set())
                killed.append(pgid)
                if not injected:
                    injected.append(True)
                    raise interruption
                return original_kill(pgid, sig)
            def wait(child, *args, **kwargs):
                self.assertTrue({p.pid for p in cohort._pipes.children}.issubset(killed))
                return original_wait(child, *args, **kwargs)
            with patch('worker_processes.os.killpg', kill), patch.object(subprocess.Popen, 'wait', wait):
                with self.assertRaises(type(interruption)) as caught:
                    cohort.close()
            self.assertIs(caught.exception, interruption)
            self.assert_closed(cohort)
            self.assertTrue(any('killpg:' in error and type(interruption).__name__ in error
                                for error in cohort._pipes.cleanup_errors))

    def test_unprintable_kill_and_wait_errors_do_not_skip_cleanup(self):
        original_kill, original_wait = os.killpg, subprocess.Popen.wait
        for location in ('killpg', 'wait'):
            cohort = self.cohort(location)
            cohort.__enter__()
            injected = []
            def kill(pgid, sig):
                if location == 'killpg' and not injected:
                    injected.append(True); raise UnprintableCleanupError()
                return original_kill(pgid, sig)
            def wait(child, *args, **kwargs):
                if location == 'wait' and not injected:
                    injected.append(True); raise UnprintableCleanupError()
                return original_wait(child, *args, **kwargs)
            with patch('worker_processes.os.killpg', kill), patch.object(subprocess.Popen, 'wait', wait):
                with self.assertRaisesRegex(ValueError, 'Clean close requires') as caught:
                    cohort.close()
            self.assert_closed(cohort)
            self.assertTrue(any('UnprintableCleanupError: message unavailable (RuntimeError)' in error
                                for error in caught.exception.worker_cleanup_errors))

    def test_original_operator_interrupt_remains_primary(self):
        cohort = self.cohort('primary')
        original_kill, injected = os.killpg, []
        original = KeyboardInterrupt()
        def kill(pgid, sig):
            if not injected:
                injected.append(True); raise SystemExit(19)
            return original_kill(pgid, sig)
        with patch('worker_processes.os.killpg', kill):
            with self.assertRaises(KeyboardInterrupt) as caught:
                with cohort:
                    raise original
        self.assertIs(caught.exception, original)
        self.assert_closed(cohort)
        self.assertTrue(any('SystemExit: 19' in error for error in original.worker_cleanup_errors))

    def test_unretired_group_keeps_watchdog_and_allows_later_teardown(self):
        class FakeTimer:
            cancelled = False
            def cancel(self):
                self.cancelled = True
        class FakeChild:
            pid = 123456789  # Every use is inside the patched killpg scope.
            returncode = None
            terminal = False
            def __init__(self):
                self.stdin, self.stdout, self.stderr = io.BytesIO(), io.BytesIO(), io.BytesIO()
            def wait(self, timeout):
                if not self.terminal:
                    raise subprocess.TimeoutExpired('invented-child', timeout)
                self.returncode = 0
        pipes = PipeWorkers([], Path(self.temp.name) / 'unused', 5, lambda phase: None)
        child = FakeChild(); pipes.children = [child]; pipes.timer = FakeTimer()
        with patch('worker_processes.os.killpg', lambda *args: None):
            try:
                pipes.close()
                self.assertFalse(pipes.closed)
                self.assertFalse(pipes.timer.cancelled)
                with self.assertRaises(ValueError):
                    pipes.check()
                child.terminal = True
                pipes.close()
                self.assertTrue(pipes.closed)
                self.assertTrue(pipes.timer.cancelled)
            finally:
                child.terminal = True
                pipes.close()


if __name__ == '__main__':
    unittest.main()
