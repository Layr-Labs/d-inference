"""Actual Python-only exited leaders with living descendants in owned groups."""

import os
from pathlib import Path
import signal
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

from worker_contract import WorkerSpec
from worker_processes import PipeWorkers


LEADER = '''
import os, time
descendant = os.fork()
if descendant == 0:
    for descriptor in (0, 1, 2):
        os.close(descriptor)
    time.sleep(30)
    os._exit(0)
os.write(1, (str(descendant) + "\\n").encode("ascii"))
os._exit(0)
'''


class CleanupV3Tests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)

    def exited_leader(self, name):
        spec = WorkerSpec((sys.executable, '-B', '-u', '-c', LEADER),
                          {'PYTHONDONTWRITEBYTECODE': '1'}, 'solo', None)
        pipes = PipeWorkers([spec], Path(self.temp.name) / name, 10, lambda phase: None)
        original_kill = os.killpg

        def cleanup():
            # Always use the real syscall, even if the test assertion fails
            # inside an injected-failure scope. No unrelated group is used.
            for child in pipes.children:
                try:
                    original_kill(child.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                child.wait(timeout=3)
            try:
                pipes.close()
            except (KeyboardInterrupt, SystemExit):
                # An already asserted interruption remains retained by owner.
                pass
            if pipes.timer is not None:
                pipes.timer.cancel()

        self.addCleanup(cleanup)
        pipes.start()
        child = pipes.children[0]
        raw = bytearray()
        end = time.monotonic() + 3
        while time.monotonic() < end:
            try:
                raw.extend(os.read(child.stdout.fileno(), 128))
            except BlockingIOError:
                pass
            if raw.endswith(b'\n') and child.poll() is not None:
                break
            time.sleep(0.01)
        self.assertEqual(child.returncode, 0)
        self.assertTrue(raw.endswith(b'\n'))
        descendant = int(raw)
        self.assertNotEqual(descendant, child.pid)
        os.kill(descendant, 0)
        original_kill(child.pid, 0)
        return pipes, child.pid, descendant

    def assert_group_gone(self, pgid):
        end = time.monotonic() + 3
        while time.monotonic() < end:
            try:
                os.killpg(pgid, 0)
            except ProcessLookupError:
                return
            time.sleep(0.01)
        self.fail('Invented descendant group did not disappear after SIGKILL')

    def test_dead_leader_first_signal_interrupt_retries_descendant_fence(self):
        for interruption in (KeyboardInterrupt(), SystemExit(23)):
            pipes, pgid, descendant = self.exited_leader(type(interruption).__name__)
            original_kill, calls = os.killpg, []

            def kill(group, sig):
                self.assertEqual((group, sig), (pgid, signal.SIGKILL))
                calls.append(group)
                if len(calls) == 1:
                    self.assertFalse(pipes.closed)
                    self.assertFalse(pipes.timer.finished.is_set())
                    os.kill(descendant, 0)
                    raise interruption
                return original_kill(group, sig)

            with patch('worker_processes.os.killpg', kill):
                with self.assertRaises(type(interruption)) as caught:
                    pipes.close()
            self.assertIs(caught.exception, interruption)
            self.assertEqual(calls, [pgid, pgid])
            self.assertTrue(pipes.closed)
            self.assertIn(pgid, pipes._fenced_groups)
            self.assertTrue(pipes.timer.finished.is_set())
            self.assert_group_gone(pgid)

    def test_dead_leader_unresolved_group_keeps_watchdog_and_retry(self):
        pipes, pgid, descendant = self.exited_leader('unresolved')
        calls = []

        def failed(group, sig):
            self.assertEqual((group, sig), (pgid, signal.SIGKILL))
            calls.append(group)
            raise PermissionError('Invented group signal refusal')

        with patch('worker_processes.os.killpg', failed):
            pipes.close()
        self.assertEqual(calls, [pgid, pgid])
        self.assertFalse(pipes.closed)
        self.assertNotIn(pgid, pipes._fenced_groups)
        self.assertFalse(pipes.timer.finished.is_set())
        self.assertEqual(pipes.children[0].returncode, 0)
        os.kill(descendant, 0)
        os.killpg(pgid, 0)
        with self.assertRaises(ValueError):
            pipes.check()
        with self.assertRaises(ValueError):
            pipes.retained_streams()
        self.assertEqual(len(pipes.cleanup_errors), 2)
        pipes.close()
        self.assertTrue(pipes.closed)
        self.assertTrue(pipes.timer.finished.is_set())
        self.assert_group_gone(pgid)

    def test_graceful_dead_leader_does_not_hide_living_group(self):
        pipes, pgid, _ = self.exited_leader('graceful')
        pipes.close(kill=False)
        self.assertTrue(pipes.closed)
        self.assertTrue(pipes.timer.finished.is_set())
        self.assertTrue(any('Owned group remains after graceful worker exit' in error
                            for error in pipes.cleanup_errors))
        self.assertFalse(pipes.complete_output)
        self.assert_group_gone(pgid)


if __name__ == '__main__':
    unittest.main()
