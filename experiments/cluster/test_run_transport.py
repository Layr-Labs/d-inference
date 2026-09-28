"""Local process-lifecycle checks; no SSH access or RDMA hardware required."""

import base64
import hashlib
import json
import os
import pathlib
import signal
import subprocess
import sys
import tempfile
import time
import unittest

import run_transport


class LauncherTests(unittest.TestCase):
    def test_native_deadline_cannot_exceed_supervisor(self):
        cases = [([], 9), (['--timeout-seconds', '30'], 9),
                 (['--timeout-seconds=3'], 3),
                 (['--timeout-seconds', '4', '--timeout-seconds', '20'], 4)]
        for arguments, expected in cases:
            with self.subTest(arguments=arguments):
                self.assertEqual(
                    run_transport.bounded_probe_args(['--mode', 'metal', *arguments], 9),
                    ['--mode', 'metal', '--timeout-seconds', str(expected)],
                )
        with self.assertRaises(ValueError):
            run_transport.bounded_probe_args(['--timeout-seconds', '0'], 9)

    def test_binary_verification_rejects_changed_bytes(self):
        with tempfile.TemporaryDirectory() as temporary:
            binary = pathlib.Path(temporary) / 'binary'
            binary.write_bytes(b'one executable snapshot')
            digest = hashlib.sha256(binary.read_bytes()).hexdigest()
            command = [sys.executable, '-c', run_transport.VERIFY_BINARY, str(binary), digest]
            self.assertEqual(subprocess.run(command, capture_output=True).returncode, 0)
            binary.write_bytes(b'a different executable')
            self.assertNotEqual(subprocess.run(command, capture_output=True).returncode, 0)

    def test_output_inside_repository_rejected_through_symlink(self):
        repository = pathlib.Path(run_transport.__file__).resolve().parents[2]
        with tempfile.TemporaryDirectory() as temporary:
            link = pathlib.Path(temporary) / 'repository-link'
            link.symlink_to(repository, target_is_directory=True)
            output = link / 'should-not-be-created-by-launcher-test'
            command = [sys.executable, run_transport.__file__,
                       '--host', 'unused-a', '--host', 'unused-b',
                       '--device', 'rdma_en1', '--device', 'rdma_en1',
                       '--coordinator', '192.0.2.1:29570',
                       '--binary', sys.executable, '--output', str(output)]
            result = subprocess.run(command, capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 2)
            self.assertIn('outside the repository', result.stderr)
            self.assertFalse(output.exists())

    def exercise_supervisor(self, interruption):
        with tempfile.TemporaryDirectory() as temporary:
            directory = pathlib.Path(temporary)
            binary = directory / 'cluster-transport-probe'
            binary.write_text(
                f'#!{sys.executable}\n'
                'import os, pathlib, signal, time\n'
                'signal.alarm(15)\n'
                'pathlib.Path(__file__).with_suffix(".pid").write_text(str(os.getpid()))\n'
                'time.sleep(10)\n'
            )
            binary.chmod(0o700)
            cfg = dict(directory=str(directory), devices=[[None, 'rdma_en1'], ['rdma_en1', None]],
                       rank=0, coordinator='192.0.2.1:29570', args=[], timeout=1)
            payload = base64.b64encode(json.dumps(cfg).encode()).decode()
            supervisor = subprocess.Popen([sys.executable, '-c', run_transport.REMOTE_RUNNER, payload],
                                          stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            pid = None
            try:
                expires = time.monotonic() + 5
                pid_file = binary.with_suffix('.pid')
                while not pid_file.exists() and time.monotonic() < expires:
                    time.sleep(0.01)
                self.assertTrue(pid_file.exists(), 'child never started')
                pid = int(pid_file.read_text())
                if interruption is not None:
                    supervisor.send_signal(interruption)
                supervisor.communicate(timeout=5)
                expected = 124 if interruption is None else 128 + interruption
                self.assertEqual(supervisor.returncode, expected)
                with self.assertRaises(ProcessLookupError):
                    os.kill(pid, 0)
            finally:
                if supervisor.poll() is None:
                    supervisor.kill()
                    supervisor.communicate()
                if pid is not None:
                    try:
                        os.killpg(pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass

    def test_timeout_reaps_detached_child(self):
        self.exercise_supervisor(None)

    def test_signals_reap_detached_child(self):
        for signum in (signal.SIGHUP, signal.SIGTERM, signal.SIGINT):
            with self.subTest(signum=signum):
                self.exercise_supervisor(signum)


if __name__ == '__main__':
    unittest.main()
