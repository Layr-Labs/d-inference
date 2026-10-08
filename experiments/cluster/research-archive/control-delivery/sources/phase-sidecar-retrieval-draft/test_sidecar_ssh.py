import shlex
import subprocess
import tempfile
from pathlib import Path
import unittest
from unittest.mock import patch

from retrieval_test_fixture import FakeChild, FakeSelector, make_run
from retrieve_phase_sidecar import retrieve
from sidecar_ssh import MAX_STDERR, MAX_STDOUT, SSHReadFailure, command, read_over_ssh


class SSHTests(unittest.TestCase):
    def setUp(self):
        self.guards = [patch('subprocess.Popen', side_effect=AssertionError('No actual subprocess')),
                       patch('subprocess.run', side_effect=AssertionError('No actual subprocess')),
                       patch('socket.socket', side_effect=AssertionError('No actual socket'))]
        for guard in self.guards:
            guard.start()
    def tearDown(self):
        for guard in reversed(self.guards):
            guard.stop()
    def call(self, child, **options):
        killed, invocation = [], []
        def factory(argv, **kwargs):
            invocation.append((argv, kwargs))
            return child
        result = read_over_ssh('test-host', '/tmp/run/native/phase-trace.json', 'print("fixture")',
            popen=factory, selector_factory=FakeSelector, clock=lambda: 0,
            read=child.read, killpg=lambda *args: killed.append(args), **options)
        return result, killed, invocation
    def test_exact_pipe_data_eof_then_wait_and_only_local_reaping(self):
        child = FakeChild(stdout=b'raw\x00bytes')
        (stdout, stderr, observed), killed, invocation = self.call(child)
        self.assertEqual(stdout, b'raw\x00bytes')
        self.assertEqual(stderr, b'')
        self.assertEqual(killed, [])
        self.assertTrue(observed['local_reader_ssh_client_reaped'])
        self.assertFalse(observed['remote_process_reaping_verified'])
        self.assertTrue(child.stdout.closed and child.stderr.closed)
        self.assertEqual(child.waits, 1)
        self.assertTrue(invocation[0][1]['start_new_session'])
        self.assertEqual(invocation[0][1]['stdin'], subprocess.DEVNULL)
    def test_remote_payload_and_path_are_single_quoted_argv(self):
        payload = 'print("a;$(false)`quoted`")\n'
        argv = command('test-host', '/tmp/run/native/phase-trace.json', payload)
        self.assertEqual(argv[-2], 'test-host')
        self.assertEqual(shlex.split(argv[-1]), ['/usr/bin/python3', '-c', payload,
                                                '/tmp/run/native/phase-trace.json'])
    def test_nonzero_or_stderr_fails_even_when_reaped(self):
        for child in (FakeChild(code=1), FakeChild(stderr=b'unexpected')):
            with self.assertRaises(SSHReadFailure) as failure:
                self.call(child)
            self.assertTrue(failure.exception.observation['local_reader_ssh_client_reaped'])
            self.assertEqual(failure.exception.cleanup, [])
    def test_stdout_and_stderr_caps_abort_and_reap(self):
        for child, expected in [(FakeChild(stdout=b'x' * (MAX_STDOUT + 50)), MAX_STDOUT + 1),
                                (FakeChild(stderr=b'x' * (MAX_STDERR + 50)), MAX_STDERR + 1)]:
            killed = []
            with self.assertRaises(SSHReadFailure) as failure:
                read_over_ssh('host', '/tmp/phase-trace.json', 'fixture', popen=lambda *a, **k: child,
                    selector_factory=FakeSelector, clock=lambda: 0, read=child.read,
                    killpg=lambda *args: killed.append(args))
            error = failure.exception
            self.assertIn('exceeded its byte cap', error.primary['error'])
            self.assertTrue(error.observation['local_reader_ssh_client_reaped'])
            self.assertEqual(len(error.stdout if len(error.stdout) > MAX_STDOUT else error.stderr), expected)
            self.assertEqual(len(killed), 1)
    def test_parent_deadline_with_no_output_kills_only_owned_group(self):
        class QuietSelector(FakeSelector):
            def select(self, timeout):
                return []
        tick = -1
        def clock():
            nonlocal tick
            tick += 1
            return tick
        child, killed = FakeChild(), []
        with self.assertRaises(SSHReadFailure) as failure:
            read_over_ssh('host', '/tmp/phase-trace.json', 'fixture', popen=lambda *a, **k: child,
                selector_factory=QuietSelector, clock=clock, read=child.read,
                killpg=lambda *args: killed.append(args))
        self.assertIn('20 second deadline', failure.exception.primary['error'])
        self.assertEqual(killed[0][0], child.pid)
        self.assertTrue(failure.exception.observation['local_reader_ssh_client_reaped'])
    def test_primary_failure_survives_kill_and_wait_failures(self):
        child = FakeChild(stdout=b'x' * (MAX_STDOUT + 1))
        def fail_wait(timeout):
            raise TimeoutError('fabricated wait failure')
        def fail_kill(*args):
            raise OSError('fabricated kill failure')
        child.wait = fail_wait
        with self.assertRaises(SSHReadFailure) as failure:
            read_over_ssh('host', '/tmp/phase-trace.json', 'fixture', popen=lambda *a, **k: child,
                selector_factory=FakeSelector, clock=lambda: 0, read=child.read, killpg=fail_kill)
        error = failure.exception
        self.assertIn('exceeded its byte cap', error.primary['error'])
        self.assertEqual(len(error.cleanup), 2)
        self.assertFalse(error.observation['local_reader_ssh_client_reaped'])
    def test_failed_ssh_receipt_preserves_primary_cleanup_no_sidecar(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            run, _, pin = make_run(root)
            primary, cleanup = dict(operation='read', error='first'), [dict(operation='wait', error='second')]
            def reader(*args):
                raise SSHReadFailure(primary, cleanup, dict(local_reader_ssh_client_reaped=False), b'partial', b'error')
            result = retrieve(run, pin, root / 'out', reader=reader)
            self.assertEqual(result['primary_failure'], primary)
            self.assertEqual(result['cleanup_errors'], cleanup)
            self.assertFalse(result['passed'])
            self.assertFalse((root / 'out/phase-trace.json').exists())
            self.assertEqual((root / 'out/ssh.stdout.bin').read_bytes(), b'partial')


if __name__ == '__main__':
    unittest.main()
