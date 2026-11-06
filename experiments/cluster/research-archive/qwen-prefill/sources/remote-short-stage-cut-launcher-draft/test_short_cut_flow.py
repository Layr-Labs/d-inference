"""Fake staging/supervision controls; no process or network work."""
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
import launch_remote_short_cut as launcher
from prefill_compute_archive import digest, write_json
from long_reference_inputs import ARTIFACT, CONFIGURATION
from short_cut_test_fixture import (Child, RAW_PROMPT, PROMPT_SHA, RAW_TEACHER, TEACHER_SHA,
    RAW_ORIGIN, RAW_PREFIX, RAW_TEXT, RUN_ID, rows, pinned_inputs)
from remote_prefill_client import collect_metadata
from remote_prefill_paths import paths


class Tests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(); self.addCleanup(temp.cleanup)
        self.path = Path(temp.name).resolve()
        for name in ('subprocess.run', 'subprocess.Popen', 'socket.socket'):
            guard = patch(name, side_effect=AssertionError('Real process/socket forbidden'))
            guard.start(); self.addCleanup(guard.stop)

    def run_fake(self, initial_refused=False, wrong_final_prompt=False, native_failure=False,
                 cleanup_failure=False, postflight_failure=False, wrong_final_teacher=False):
        runtime = self.path / 'repo/experiments/cluster/runtime'; runtime.mkdir(parents=True)
        release = self.path / 'release'; release.mkdir()
        prompt = self.path / 'prompt.json'; prompt.write_bytes(RAW_PROMPT)
        origin = self.path / 'origin.json'; origin.write_bytes(RAW_ORIGIN)
        teacher = self.path / 'teacher.json'; teacher.write_bytes(RAW_TEACHER)
        prefix = self.path / 'prefix.json'; prefix.write_bytes(RAW_PREFIX)
        text_file = self.path / 'source.txt'; text_file.write_bytes(RAW_TEXT)
        output = self.path / 'output'
        operations, uploads, starts, stops = [], [], [], []
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
            (output / 'native/stdout.jsonl').write_text('' if native_failure else ''.join(json.dumps(x) + '\n' for x in rows()))
            return Child(255 if native_failure else 0)
        def stop(ranks, children):
            stops.append((ranks, children))
            if cleanup_failure: raise OSError('fake owned cancellation failure')
        def upload(processes, host, source, destination):
            uploads.append((str(source), destination))
            if destination.endswith('/prompt.json'):
                self.assertEqual(Path(source).read_bytes(), RAW_PROMPT)
            if destination.endswith('/teacher.json'):
                self.assertEqual(Path(source).read_bytes(), RAW_TEACHER)
        memory = dict(pressure_level=1, swap_used_bytes='0', remote_pid_inventory=dict(observed_processes=[]))
        class Control:
            def __init__(self, *args): pass
            def call(self, operation, timeout=120):
                operations.append(operation)
                if operation == 'initial': return dict(passed=not initial_refused, actual_free_bytes=(5 if initial_refused else 6) * 1024**3)
                if operation == 'observe': return copy.deepcopy(memory)
                config = json.loads((output / 'controls/control-config.json').read_text())
                manifest = json.loads((output / 'bundle/bundle.json').read_text())
                result = dict(artifact_aggregate_sha256=ARTIFACT, bundle_manifest_sha256=config['bundle_sha256'],
                    rank_configuration_sha256=config['rank_sha256'], memory=copy.deepcopy(memory),
                    bundle_file_sha256={entry['path']: entry['sha256'] for entry in manifest['files']},
                    model_metadata={'config.json': dict(sha256=CONFIGURATION), 'manifest.json': dict(sha256='f' * 64)},
                    prompt_sha256='f' * 64 if operation == 'after' and wrong_final_prompt else PROMPT_SHA,
                    prompt_size_bytes=len(RAW_PROMPT), raw_prompt_reencoded=False,
                    teacher_sha256='f' * 64 if operation == 'after' and wrong_final_teacher else TEACHER_SHA,
                    teacher_size_bytes=len(RAW_TEACHER), raw_teacher_reencoded=False)
                if operation == 'before': result['posthash_preflight'] = dict(passed=True)
                if operation == 'after' and postflight_failure: raise ValueError('postflight unavailable')
                return result
        modules = dict(bundle=SimpleNamespace(snapshot=snapshot),
            processes=SimpleNamespace(start=start, stop_processes=stop),
            artifacts=SimpleNamespace(verify_files=lambda *args: None))
        args = ['--release', str(release), '--runtime', str(runtime), '--output', str(output),
            '--prompt-file', str(prompt), '--prompt-sha256', PROMPT_SHA,
            '--teacher-file', str(teacher), '--teacher-sha256', TEACHER_SHA,
            '--prompt-prefix-file', str(prefix), '--source-text-file', str(text_file),
            '--prompt-origin-file', str(origin), '--prompt-origin-sha256', digest(origin),
            '--host', 'fixture-peer', '--remote-model-dir', '/models/fixture',
            '--artifact-aggregate-sha256', ARTIFACT, '--expected-native-sha256', hashlib.sha256(binary).hexdigest()]
        with pinned_inputs(), patch.object(launcher, 'archive_launcher', return_value=[]), \
             patch.object(launcher, 'archive_sources', side_effect=archive), \
             patch.object(launcher, 'load_archived_runtime', return_value=modules), \
             patch.object(launcher, 'verify_archive'), patch.object(launcher, 'verify_local'), \
             patch.object(launcher, 'create_remote', return_value=layout), \
             patch.object(launcher, 'RemoteControl', Control), patch.object(launcher, 'upload_new', side_effect=upload), \
             patch.object(launcher, 'collect_metadata', return_value=[]), contextlib.redirect_stdout(io.StringIO()):
            status = launcher.main(args)
        return status, json.loads((output / 'receipt.json').read_text()), operations, uploads, starts, stops

    def test_raw_prompt_staging_and_exact_ready_report_success(self):
        status, receipt, operations, uploads, starts, stops = self.run_fake()
        self.assertEqual(status, 0); self.assertTrue(receipt['passed'])
        self.assertEqual(operations, ['initial', 'before', 'observe', 'after'])
        self.assertEqual(len(starts), 1); self.assertFalse(stops)
        self.assertTrue(uploads[-1][1].endswith('/teacher.json'))
        self.assertTrue(uploads[-2][1].endswith('/prompt.json'))
        self.assertEqual(receipt['remote_paths']['bundle'], receipt['remote_paths']['native'] + '/bundle')
        config = json.loads((self.path / 'output/native/rank.json').read_text())
        self.assertEqual(config['input_files'], {}); self.assertEqual(config['timeout_seconds'], 180)
        self.assertFalse(receipt['timing_requested']); self.assertFalse(receipt['independent_numerical_audit_passed']); self.assertEqual(receipt['execution']['validated_outer_records'], 2)
        self.assertIsNone(receipt['primary_failure']); self.assertFalse(receipt['cleanup_errors'])

    def test_initial_free_refusal_precedes_bundle_and_prompt_upload(self):
        status, receipt, operations, uploads, starts, _ = self.run_fake(initial_refused=True)
        self.assertEqual(status, 1); self.assertEqual(operations, ['initial'])
        self.assertEqual(len(uploads), 1); self.assertTrue(uploads[0][1].endswith('/controls'))
        self.assertFalse(starts); self.assertFalse(receipt['native_execution_attempted'])

    def test_final_raw_prompt_change_fails_and_cancels_owned_run(self):
        status, receipt, _, _, _, stops = self.run_fake(wrong_final_prompt=True)
        self.assertEqual(status, 1); self.assertTrue(stops)
        self.assertIn('raw prompt', receipt['primary_failure']['error'])
        self.assertTrue(receipt['execution']['passed']); self.assertFalse(receipt['passed'])

    def test_final_teacher_change_fails_without_losing_primary_reason(self):
        status, receipt, _, _, _, stops = self.run_fake(wrong_final_teacher=True)
        self.assertEqual(status, 1); self.assertTrue(stops)
        self.assertIn('raw teacher', receipt['primary_failure']['error'])

    def test_native_primary_failure_survives_postflight_and_cleanup_errors(self):
        status, receipt, _, _, _, stops = self.run_fake(native_failure=True, cleanup_failure=True, postflight_failure=True)
        self.assertEqual(status, 1); self.assertTrue(stops)
        self.assertEqual(receipt['primary_failure']['operation'], 'native_supervision')
        self.assertEqual(receipt['primary_failure']['reason'], 'native_remote_supervisor_or_ssh_failed')
        self.assertIn('postflight unavailable', receipt['post_run_errors'][0]['error'])
        self.assertGreaterEqual(len(receipt['cleanup_errors']), 2)

    def test_output_archive_error_does_not_replace_native_primary_failure(self):
        with patch.object(launcher, 'native_file_receipts', side_effect=OSError('output archive unavailable')):
            status, receipt, _, _, _, _ = self.run_fake(native_failure=True)
        self.assertEqual(status, 1)
        self.assertEqual(receipt['primary_failure']['operation'], 'native_supervision')
        self.assertEqual(receipt['post_run_errors'][-1]['operation'], 'archive_native_outputs')

    def test_retrieval_verifies_actual_final_raw_prompt_bytes(self):
        layout = dict(run='/owned', native='/owned/native')
        blobs = {'rank.final.json': b'{}', 'prompt.final.json': RAW_PROMPT, 'teacher.final.json': RAW_TEACHER}
        before, after = {}, {}
        for phase, record in [('before', before), ('after', after)]:
            record['model_metadata'] = {}
            for name in ('config.json', 'manifest.json'):
                saved = phase + '-' + name; blobs[saved] = saved.encode()
                record['model_metadata'][name] = dict(remote_path='/owned/metadata/' + saved,
                    sha256=hashlib.sha256(blobs[saved]).hexdigest())
        after.update(rank_configuration_sha256=hashlib.sha256(b'{}').hexdigest(), prompt_sha256=PROMPT_SHA, teacher_sha256=TEACHER_SHA)
        class Process:
            @staticmethod
            def scp(source, destination):
                path = Path(destination); path.write_bytes(blobs[path.name])
        saved = collect_metadata(Process, 'fixture-peer', layout, before, after, self.path)
        self.assertEqual(len(saved), 7)
        self.assertEqual((self.path / 'remote-metadata/prompt.final.json').read_bytes(), RAW_PROMPT)
        self.assertEqual((self.path / 'remote-metadata/teacher.final.json').read_bytes(), RAW_TEACHER)


if __name__ == '__main__': unittest.main()
