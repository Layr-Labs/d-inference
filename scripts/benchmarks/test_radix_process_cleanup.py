"""Owned process-group cleanup races, entirely stubbed without signaling a host."""
import signal
import subprocess
import unittest
from unittest.mock import Mock, call, patch

from run_radix_http import terminate


class ProcessCleanupTests(unittest.TestCase):
    def process(self):
        return Mock(pid=12345, poll=Mock(return_value=None))

    def test_disappearance_before_term_still_reaps_the_owned_process(self):
        process = self.process()
        with patch("run_radix_http.os.killpg", side_effect=ProcessLookupError) as kill:
            terminate(process)
        kill.assert_called_once_with(process.pid, signal.SIGTERM)
        process.wait.assert_called_once_with(timeout=5)

    def test_disappearance_before_kill_still_reaps_the_owned_process(self):
        process = self.process()
        process.wait.side_effect = [subprocess.TimeoutExpired("fixture", 5), 0]
        with patch("run_radix_http.os.killpg", side_effect=[None, ProcessLookupError]) as kill:
            terminate(process)
        self.assertEqual(kill.call_args_list, [call(process.pid, signal.SIGTERM), call(process.pid, signal.SIGKILL)])
        self.assertEqual(process.wait.call_args_list, [call(timeout=5), call(timeout=5)])

    def test_gone_processes_are_not_signaled_and_real_failures_propagate(self):
        with patch("run_radix_http.os.killpg") as kill:
            terminate(None)
            terminate(Mock(poll=Mock(return_value=0)))
        kill.assert_not_called()
        process = self.process()
        with patch("run_radix_http.os.killpg", side_effect=PermissionError), self.assertRaises(PermissionError):
            terminate(process)
        process.wait.assert_not_called()
        process.wait.side_effect = subprocess.TimeoutExpired("fixture", 5)
        with patch("run_radix_http.os.killpg"), self.assertRaises(subprocess.TimeoutExpired):
            terminate(process)
