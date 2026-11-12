"""Fake end-to-end coordinator checks; never starts a process or contacts a host."""
import contextlib
import copy
import hashlib
import io
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import launch_remote_solo_prefill as launcher
from prefill_compute_archive import digest, write_json
from prefill_compute_inputs import ARTIFACT, CONFIGURATION
from remote_prefill_paths import paths
from test_remote_solo_prefill import Child, PROMPT, RUN_ID, fixture, reference


class Tests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name).resolve()
        for name in ('subprocess.run', 'subprocess.Popen', 'socket.socket'):
            guard = patch(name, side_effect=AssertionError('Real process/socket creation forbidden'))
            guard.start(); self.addCleanup(guard.stop)

    def run_fake(self, after_bad_reference=False, native_failure=False, cleanup_failure=False, bad_native_pin=False):
        runtime = self.path / 'repo/experiments/cluster/runtime'; runtime.mkdir(parents=True)
        release = self.path / 'release'; release.mkdir()
        origin = self.path / 'origin'; origin.mkdir()
        inventory = self.path / 'inventory.json'; inventory.write_text('{}')
        output = self.path / 'output'; operations, starts, stops = [], [], []
        binary = b'non-executable CPU fixture'
        layout = paths('/Users/fixture', None, '/models/fixture', RUN_ID)
        def snapshot(source, destination):
            destination.mkdir()
            (destination / 'cluster-inference').write_bytes(binary)
            (destination / 'artifacts.py').write_text('# fake artifact verifier\n')
            write_json(destination / 'bundle.json', dict(files=[dict(path=p.name, sha256=digest(p)) for p in destination.iterdir()]))
            return digest(destination / 'bundle.json')
        def archive(source, destination):
            write_json(destination / 'source-manifest.json', dict(files=[])); return dict(files=[])
        def start(rank):
            starts.append(rank)
            rows = [] if native_failure else fixture()
            (output / 'native/stdout.jsonl').write_text(''.join(json.dumps(row) + '\n' for row in rows))
            return Child(255 if native_failure else 0)
        def stop(ranks, children):
            stops.append((ranks, children))
            if cleanup_failure: raise OSError('fake owned cancellation failure')
        memory = dict(pressure_level=1, swap_used_bytes='0', remote_pid_inventory=dict(observed_processes=[]))
        class Control:
            def __init__(self, *args): pass
            def call(self, operation, timeout=120):
                operations.append(operation)
                if operation == 'initial': return dict(passed=True, actual_free_bytes=6 * 1024**3)
                if operation == 'observe': return copy.deepcopy(memory)
                config = json.loads((output / 'controls/control-config.json').read_text())
                manifest = json.loads((output / 'bundle/bundle.json').read_text())
                result = dict(artifact_aggregate_sha256=ARTIFACT, bundle_manifest_sha256=config['bundle_sha256'],
                    rank_configuration_sha256=config['rank_sha256'], memory=copy.deepcopy(memory),
                    bundle_file_sha256={entry['path']: entry['sha256'] for entry in manifest['files']},
                    model_metadata={'config.json': dict(sha256=CONFIGURATION), 'manifest.json': dict(sha256='f' * 64)})
                if operation == 'before': result['posthash_preflight'] = dict(passed=True)
                else:
                    result['prompt_sha256'] = config['prompt_sha256']
                    result['solo_reference_sha256'] = 'f' * 64 if after_bad_reference else config['solo_reference_sha256']
                return result
        modules = dict(bundle=SimpleNamespace(snapshot=snapshot),
                       processes=SimpleNamespace(start=start, stop_processes=stop),
                       artifacts=SimpleNamespace(verify_files=lambda *args: None))
        args = ['--release', str(release), '--runtime', str(runtime), '--output', str(output),
            '--input-origin', str(origin), '--expected-inventory', str(inventory), '--host', 'fixture-peer',
            '--remote-model-dir', '/models/fixture', '--artifact-aggregate-sha256', ARTIFACT,
            '--expected-native-sha256', 'e' * 64 if bad_native_pin else hashlib.sha256(binary).hexdigest(),
            '--solo-reference', str(self.path / 'reference.json')]
        with patch.object(launcher, 'archive_launcher', return_value=[]), \
             patch.object(launcher, 'archive_sources', side_effect=archive), \
             patch.object(launcher, 'load_archived_runtime', return_value=modules), \
             patch.object(launcher, 'verify_archive'), \
             patch.object(launcher, 'archive_inputs', return_value=dict(prompt=PROMPT, teacher=[], files=[])), \
             patch.object(launcher, 'archive_reference', return_value=reference()), \
             patch.object(launcher, 'create_remote', return_value=layout), \
             patch.object(launcher, 'RemoteControl', Control), \
             patch.object(launcher, 'upload_new'), patch.object(launcher, 'collect_metadata', return_value=[]), \
             contextlib.redirect_stdout(io.StringIO()):
            status = launcher.main(args)
        return status, json.loads((output / 'receipt.json').read_text()), operations, starts, stops

    def test_success_uses_only_ready_then_report_and_no_baseline_forward(self):
        status, receipt, operations, starts, stops = self.run_fake()
        self.assertEqual(status, 0); self.assertTrue(receipt['passed'])
        self.assertEqual(operations, ['initial', 'before', 'observe', 'after'])
        self.assertEqual(len(starts), 1); self.assertFalse(stops)
        self.assertFalse(receipt['native_baseline_forward'])
        self.assertEqual(receipt['execution']['validated_outer_records'], 2)
        self.assertIsNone(receipt['primary_failure']); self.assertFalse(receipt['cleanup_errors'])
        self.assertEqual(receipt['reference']['staged_file_sha256'], receipt['remote_after']['solo_reference_sha256'])

    def test_postrun_actual_reference_hash_failure_cancels_owned_run(self):
        status, receipt, _, _, stops = self.run_fake(after_bad_reference=True)
        self.assertEqual(status, 1); self.assertTrue(stops)
        self.assertIn('Remote input bytes changed', receipt['primary_failure']['error'])
        self.assertNotIn('source_bundle_inputs_and_remote_model_unchanged_after_run', receipt)

    def test_native_primary_survives_postrun_and_both_cleanup_errors(self):
        status, receipt, _, _, stops = self.run_fake(after_bad_reference=True, native_failure=True, cleanup_failure=True)
        self.assertEqual(status, 1); self.assertEqual(len(stops), 2)
        self.assertEqual(receipt['primary_failure']['reason'], 'native_remote_supervisor_or_ssh_failed')
        self.assertEqual(len(receipt['cleanup_errors']), 2)
        self.assertIn('Remote input bytes changed', receipt['post_run_errors'][0]['error'])

    def test_wrong_native_pin_refuses_before_any_remote_or_native_control(self):
        status, receipt, operations, starts, stops = self.run_fake(bad_native_pin=True)
        self.assertEqual(status, 1); self.assertFalse(operations); self.assertFalse(starts); self.assertFalse(stops)
        self.assertFalse(receipt['native_execution_attempted'])
        self.assertIn('native binary pin differs', receipt['primary_failure']['error'])


if __name__ == '__main__':
    unittest.main()
