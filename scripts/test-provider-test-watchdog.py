#!/usr/bin/env python3
"""Exercise exit propagation and timeout cleanup without Swift or models."""
import json
import signal
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

WATCHDOG = Path(__file__).with_name('run-provider-test-watchdog.py')


class WatchdogTests(unittest.TestCase):
    def run_child(self, source, timeout=5):
        with tempfile.TemporaryDirectory(prefix='darkbloom-watchdog-test-') as directory:
            result = subprocess.run(
                [sys.executable, str(WATCHDOG), '--output-dir', directory,
                 '--diagnostic-after-seconds', '0.1', '--timeout-seconds', str(timeout),
                 '--', sys.executable, '-c', source],
                capture_output=True, text=True, timeout=15)
            self.assertTrue((Path(directory) / 'result.json').exists(), result.stderr)
            report = json.loads((Path(directory) / 'result.json').read_text())
            transcript = (Path(directory) / 'test-output.log').read_text()
            return result, report, transcript

    def test_success_keeps_output(self):
        result, report, transcript = self.run_child("print('tests complete')")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(transcript, 'tests complete\n')
        self.assertFalse(report['timed_out'])

    def test_failure_is_not_hidden(self):
        result, report, _ = self.run_child('raise SystemExit(7)')
        self.assertEqual(result.returncode, 7)
        self.assertEqual(report['exit_code'], 7)

    def test_timeout_stops_descendants(self):
        source = """import json,os,subprocess,sys,time
child=subprocess.Popen([sys.executable,'-c','import time;time.sleep(30)'])
print(json.dumps({'parent':os.getpid(),'child':child.pid}),flush=True)
time.sleep(30)
"""
        result, report, transcript = self.run_child(source, timeout=1)
        self.assertEqual(result.returncode, 124)
        self.assertTrue(report['timed_out'])
        for pid in json.loads(transcript).values():
            status = subprocess.run(['ps', '-p', str(pid), '-o', 'stat='], capture_output=True, text=True)
            self.assertTrue(not status.stdout.strip() or status.stdout.strip().startswith('Z'))

    def test_cancellation_is_not_success_and_stops_descendants(self):
        source = """import json,os,subprocess,sys,time
child=subprocess.Popen([sys.executable,'-c','import time;time.sleep(30)'])
print(json.dumps({'parent':os.getpid(),'child':child.pid}),flush=True)
time.sleep(30)
"""
        with tempfile.TemporaryDirectory(prefix='darkbloom-watchdog-cancel-') as directory:
            process = subprocess.Popen(
                [sys.executable, str(WATCHDOG), '--output-dir', directory,
                 '--diagnostic-after-seconds', '5', '--timeout-seconds', '10',
                 '--', sys.executable, '-c', source],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                # The watchdog forwards this only after installing its handlers.
                pids = json.loads(process.stdout.readline())
                process.send_signal(signal.SIGTERM)
                _, stderr = process.communicate(timeout=15)
                self.assertEqual(process.returncode, 128 + signal.SIGTERM, stderr)
                report = json.loads((Path(directory) / 'result.json').read_text())
                self.assertEqual(report['interrupted'], [signal.SIGTERM])
                self.assertFalse(report['timed_out'])
                for pid in pids.values():
                    status = subprocess.run(['ps', '-p', str(pid), '-o', 'stat='], capture_output=True, text=True)
                    self.assertTrue(not status.stdout.strip() or status.stdout.strip().startswith('Z'))
            finally:
                if process.poll() is None:
                    process.terminate()
                    process.communicate(timeout=15)


if __name__ == '__main__':
    unittest.main()
