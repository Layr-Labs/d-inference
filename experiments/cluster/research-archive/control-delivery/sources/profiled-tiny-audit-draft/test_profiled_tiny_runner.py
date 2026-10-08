"""Prospective fake launcher tests: every real process/socket/signal is blocked."""
import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

RUNNER = Path(__file__).parents[1] / 'run-profiled-tiny-stage-check-20260914.py'


def load_runner():
    spec = importlib.util.spec_from_file_location('prospective_tiny_runner', RUNNER)
    value = importlib.util.module_from_spec(spec); spec.loader.exec_module(value)
    return value


class Child:
    pid = 4242
    def __init__(self, code=0): self.code = code
    def poll(self): return self.code
    def wait(self, timeout=None):
        if self.code is None: raise subprocess.TimeoutExpired('fake native', timeout)
        return self.code


class Tests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name); self.runner = load_runner()
        for name in ('subprocess.run', 'subprocess.Popen', 'socket.socket', 'os.killpg'):
            guard = patch(name, side_effect=AssertionError('Real process/socket/signal forbidden'))
            guard.start(); self.addCleanup(guard.stop)

    def run_fake(self, scenario='success', cleanup_error=False):
        r = self.runner; clock = [0.0]; starts = []; verifications = [0]
        repo = self.path / 'repo'; release = repo / 'experiments/cluster/inference/.build/release'
        release.mkdir(parents=True); binary = b'CPU fixture, never executable'
        (release / 'cluster-inference').write_bytes(binary)
        helper = self.path / 'helper.py'; helper.write_text('# CPU fixture\n')
        output = self.path / 'output'; child = Child(None if scenario in ('deadline', 'pressure', 'swap') else 0)
        def write(path, value): path.write_text(json.dumps(value, sort_keys=True, indent=2) + '\n')
        def archive_sources(runtime, out):
            if scenario == 'archive': raise ValueError('original source archive failure')
            write(out / 'source-manifest.json', {'files': []}); return {'files': []}
        def snapshot(source, out):
            out.mkdir(); (out / 'cluster-inference').write_bytes(binary)
            write(out / 'bundle.json', {'files': []}); return r.sha(out / 'bundle.json')
        def verify(*args):
            verifications[0] += 1
            if scenario == 'post_archive' and verifications[0] > 1: raise ValueError('post archive drift')
        archive = SimpleNamespace(write_json=write, archive_sources=archive_sources, verify_archive=verify,
            load_archived_runtime=lambda *args: {'bundle': SimpleNamespace(snapshot=snapshot)})
        def sample(pid=None):
            record = dict(actualFreeBytes=2 * 1024**3, pressureLevel=1, reportedSwapBytes='0')
            if scenario == 'initial_free' and not (output / 'source-manifest.json').exists():
                record['actualFreeBytes'] = 512 * 1024**2
            if pid is not None:
                if scenario == 'deadline': clock[0] = 196
                if scenario == 'pressure': record['pressureLevel'] = 3
                if scenario == 'swap': record['reportedSwapBytes'] = '1'
            return record
        def start(command, **kwargs):
            starts.append((command, kwargs)); self.assertTrue(kwargs['start_new_session'])
            self.assertEqual(kwargs['env']['DARKBLOOM_CBV2_ATTN_QUERY_BLOCK'], '128')
            if scenario == 'oversize': kwargs['stdout'].write(b'x' * (8 * 1024**2 + 1)); kwargs['stdout'].flush()
            elif scenario == 'stderr': kwargs['stderr'].write(b'fault'); kwargs['stderr'].flush()
            else: kwargs['stdout'].write(b'{}\n'); kwargs['stdout'].flush()
            return child
        def stop(process):
            process.code = -15 if process.code is None else process.code
            if cleanup_error: raise OSError('independent cleanup failure')
            return []
        args = ['runner', '--output', str(output), '--workload', 'profiled',
                '--expected-native-sha256', hashlib.sha256(binary).hexdigest()]
        with patch.object(r, 'REPO', repo), patch.object(r, 'HELPER', helper), \
             patch.object(r, 'HELPER_SHA', r.sha(helper)), patch.object(sys, 'argv', args), \
             patch.object(r.importlib.util, 'spec_from_file_location', return_value=SimpleNamespace(loader=SimpleNamespace(exec_module=lambda m: None))), \
             patch.object(r.importlib.util, 'module_from_spec', return_value=archive), \
             patch.object(r, 'sample', side_effect=sample), patch.object(r, 'read_command', return_value=''), \
             patch.object(r, 'owned_group', return_value=[]), patch.object(r, 'stop_owned', side_effect=stop), \
             patch.object(r.subprocess, 'Popen', side_effect=start), \
             patch.object(r.time, 'monotonic', side_effect=lambda: clock[0]), \
             contextlib.redirect_stdout(io.StringIO()):
            status = r.main()
        return status, json.loads((output / 'receipt.json').read_text()), starts

    def test_success_archives_pins_one_owned_native_and_reaps(self):
        status, receipt, starts = self.run_fake()
        self.assertEqual(status, 0); self.assertEqual(len(starts), 1)
        self.assertTrue(receipt['nativeReaped']); self.assertEqual(receipt['nativeExecutions'], 1)
        self.assertEqual(starts[0][0][2], 'qwen-layer-stage-profiled-check')
        self.assertEqual(receipt['ownedProcessGroupAfter'], [])
        self.assertFalse(receipt['throughputQualification'])

    def test_initial_resource_refusal_and_archive_failure_never_launch(self):
        for scenario in ('initial_free', 'archive'):
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory() as temp:
                self.path = Path(temp)
                status, receipt, starts = self.run_fake(scenario)
                self.assertEqual(status, 1); self.assertFalse(starts)
                self.assertFalse(receipt['nativeExecutionAttempted'])

    def test_parent_deadline_is_independent_and_preserves_cleanup_failure(self):
        status, receipt, _ = self.run_fake('deadline', cleanup_error=True)
        self.assertEqual(status, 1); self.assertIn('Parent native deadline', receipt['primaryFailure'])
        self.assertIn('independent cleanup failure', receipt['cleanupErrors'][0])

    def test_pressure_or_new_swap_retires_the_native_process(self):
        for scenario in ('pressure', 'swap'):
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory() as temp:
                self.path = Path(temp)
                status, receipt, _ = self.run_fake(scenario)
                self.assertEqual(status, 1); self.assertTrue(receipt['nativeReaped'])
                self.assertEqual(receipt['nativeExitCode'], -15)

    def test_final_oversize_output_is_refused_and_never_hashed(self):
        status, receipt, _ = self.run_fake('oversize')
        self.assertEqual(status, 1); self.assertIn('Completed native output', receipt['primaryFailure'])
        self.assertIsNone(receipt['stdout.jsonl']['sha256'])
        self.assertTrue(receipt['stdout.jsonl']['hashOmittedBecauseOversized'])

    def test_successful_exit_with_stderr_still_fails(self):
        status, receipt, _ = self.run_fake('stderr')
        self.assertEqual(status, 1); self.assertIn('emitted stderr', receipt['primaryFailure'])

    def test_post_run_archive_failure_is_distinct(self):
        status, receipt, _ = self.run_fake('post_archive')
        self.assertEqual(status, 1); self.assertIsNone(receipt['primaryFailure'])
        self.assertIn('post archive drift', receipt['postRunErrors'][0])

    def test_cleanup_terminates_children_after_leader_exit(self):
        child, alive, signals = Child(0), [True], []
        def kill(pgid, sig): signals.append((pgid, sig)); alive[0] = False
        with patch.object(self.runner, 'owned_group', side_effect=lambda pgid: [{'pid': 4243}] if alive[0] else []), \
             patch.object(self.runner.os, 'killpg', side_effect=kill):
            self.assertEqual(self.runner.stop_owned(child), [])
        self.assertEqual(signals, [(4242, signal.SIGTERM)])

    def test_cleanup_escalates_and_reports_an_unreaped_group(self):
        child, clock, signals = Child(None), [0.0], []
        def sleep(seconds): clock[0] += seconds
        with patch.object(self.runner, 'owned_group', return_value=[{'pid': 4242}]), \
             patch.object(self.runner.os, 'killpg', side_effect=lambda pgid, sig: signals.append(sig)), \
             patch.object(self.runner.time, 'monotonic', side_effect=lambda: clock[0]), \
             patch.object(self.runner.time, 'sleep', side_effect=sleep):
            errors = self.runner.stop_owned(child)
        self.assertEqual(signals, [signal.SIGTERM, signal.SIGKILL]); self.assertEqual(len(errors), 2)
        self.assertLess(clock[0], 10.2)

    def test_owned_group_observation_does_not_match_other_groups(self):
        raw = '10 1 4242 fixture-child\n11 1 9999 unrelated\n'
        with patch.object(self.runner, 'read_command', return_value=raw):
            rows = self.runner.owned_group(4242)
        self.assertEqual([row['pid'] for row in rows], [10])


if __name__ == '__main__': unittest.main()
