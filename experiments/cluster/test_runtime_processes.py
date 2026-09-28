"""Exercise actual local process ownership; no MLX, model or SSH execution."""

import json
import hashlib
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

from runtime.bundle import snapshot
from runtime.processes import run_cohort, start


FIXTURE = '''import json, os, signal, subprocess, sys, time
from pathlib import Path
action = sys.argv[1]
descendant = subprocess.Popen([sys.executable, '-c',
    'import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(60)'])
Path('pids.json').write_text(json.dumps([os.getpid(), descendant.pid]))
if action == 'exit':
    time.sleep(0.3)
    sys.exit(7)
if action == 'success':
    print(json.dumps({'environment': {k: v for k, v in os.environ.items()
        if k.startswith(('MLX_', 'JACCL_', 'DARKBLOOM_'))}}), flush=True)
    sys.exit(0)
signal.signal(signal.SIGTERM, signal.SIG_IGN)
time.sleep(60)
'''


class ProcessLifecycleTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        source = self.root / 'source'
        source.mkdir()
        (source / 'cluster-inference').write_text(f'#!{sys.executable}\n' + FIXTURE)
        (source / 'mlx.metallib').write_text('test resource only')
        (source / 'mlx-swift-lm_MLXLMCommon.bundle').mkdir()
        (source / 'mlx-swift-lm_MLXLMCommon.bundle' / 'fixture').write_text('resource')
        self.bundle = self.root / 'bundle'
        self.bundle_hash = snapshot(source, self.bundle)
        self.workers = []

    def tearDown(self):
        # Bounded cleanup also runs on test assertion failure.
        for process in self.workers:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
        for path in self.root.glob('rank-*/pids.json'):
            for pid in json.loads(path.read_text()):
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
        self.temporary.cleanup()

    def rank(self, index=0, action='wait', timeout=5, bundle_hash=None):
        directory = self.root / f'rank-{index}'
        directory.mkdir()
        config = dict(bundle=str(self.bundle), bundle_sha256=bundle_hash or self.bundle_hash,
                      environment={'MLX_ALLOWED_FIXTURE': 'selected'}, input_files={},
                      arguments=[action], timeout_seconds=timeout)
        (directory / 'rank.json').write_text(json.dumps(config))
        return dict(rank=index, host=None, directory=str(directory), local=str(directory),
                    bundle=str(self.bundle))

    def started(self, rank):
        process = start(rank)
        self.workers.append(process)
        path = Path(rank['directory']) / 'pids.json'
        deadline = time.monotonic() + 5
        while not path.exists() and process.poll() is None and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertTrue(path.exists(), (Path(rank['local']) / 'stderr.log').read_text())
        return process

    def assert_children_stopped(self, rank):
        pids = json.loads((Path(rank['directory']) / 'pids.json').read_text())
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            live = []
            for pid in pids:
                result = subprocess.run(['ps', '-p', str(pid), '-o', 'stat='],
                                        capture_output=True, text=True)
                state = result.stdout.strip()
                if state and not state.startswith('Z'):
                    live.append(pid)
            if not live:
                return
            time.sleep(0.03)
        self.fail(f'Fixture descendants are still running: {live}')

    def test_worker_deadline_kills_entire_child_group(self):
        rank = self.rank(timeout=0.4)
        process = self.started(rank)
        self.assertEqual(process.wait(timeout=4), 124)
        self.assert_children_stopped(rank)

    def test_cancel_marker_kills_entire_child_group(self):
        rank = self.rank()
        process = self.started(rank)
        (Path(rank['directory']) / 'cancel').touch()
        self.assertEqual(process.wait(timeout=4), 125)
        self.assert_children_stopped(rank)

    def test_supervisor_signals_kill_entire_child_group(self):
        for index, signum in enumerate((signal.SIGHUP, signal.SIGINT, signal.SIGTERM)):
            with self.subTest(signal=signum):
                rank = self.rank(index)
                process = self.started(rank)
                process.send_signal(signum)
                self.assertEqual(process.wait(timeout=4), 128 + signum)
                self.assert_children_stopped(rank)

    def test_exited_leader_does_not_leave_descendants(self):
        rank = self.rank(action='exit')
        process = self.started(rank)
        self.assertEqual(process.wait(timeout=4), 7)
        self.assert_children_stopped(rank)

    def test_rank_failure_cancels_its_running_peer(self):
        ranks = [self.rank(0, action='exit'), self.rank(1)]
        receipt = run_cohort(ranks, timeout=5)
        self.assertEqual(receipt['cancellation_reason'], 'rank_failed')
        self.assertEqual(receipt['exit_codes'][0], 7)
        self.assertNotEqual(receipt['exit_codes'][1], 0)
        for rank in ranks:
            self.assert_children_stopped(rank)

    def test_cohort_deadline_cancels_all_ranks(self):
        ranks = [self.rank(0), self.rank(1)]
        receipt = run_cohort(ranks, timeout=0.5)
        self.assertEqual(receipt['cancellation_reason'], 'cohort_deadline')
        self.assertTrue(all(code != 0 for code in receipt['exit_codes']))
        for rank in ranks:
            self.assert_children_stopped(rank)

    def test_bad_bundle_identity_never_starts_child(self):
        rank = self.rank(bundle_hash='0' * 64)
        receipt = run_cohort([rank], timeout=5)
        self.assertEqual(receipt['exit_codes'], [1])
        self.assertFalse((Path(rank['directory']) / 'pids.json').exists())

    def test_worker_imports_leave_verified_bundle_unchanged(self):
        def inventory():
            return {str(path.relative_to(self.bundle)): (
                path.stat().st_mode,
                hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None)
                for path in self.bundle.rglob('*')}

        before = inventory()
        rank = self.rank(action='success')
        previous = os.environ.pop('PYTHONDONTWRITEBYTECODE', None)
        try:
            receipt = run_cohort([rank], timeout=5)
        finally:
            if previous is not None:
                os.environ['PYTHONDONTWRITEBYTECODE'] = previous
        self.assertEqual(receipt['exit_codes'], [0])
        self.assert_children_stopped(rank)
        self.assertEqual(inventory(), before)

    def test_inherited_backend_environment_is_removed(self):
        rank = self.rank(action='success')
        previous = os.environ.get('JACCL_POISON_FIXTURE')
        os.environ['JACCL_POISON_FIXTURE'] = 'inherited'
        try:
            receipt = run_cohort([rank], timeout=5)
        finally:
            if previous is None:
                del os.environ['JACCL_POISON_FIXTURE']
            else:
                os.environ['JACCL_POISON_FIXTURE'] = previous
        self.assertEqual(receipt['exit_codes'], [0])
        record = json.loads((Path(rank['local']) / 'stdout.jsonl').read_text())
        self.assertEqual(record['environment'], {'MLX_ALLOWED_FIXTURE': 'selected'})
        self.assert_children_stopped(rank)


if __name__ == '__main__':
    unittest.main()
