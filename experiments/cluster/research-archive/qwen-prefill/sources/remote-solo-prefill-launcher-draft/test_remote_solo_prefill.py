"""Pure/fake remote staging and lifecycle tests; all process/socket calls forbidden."""
import contextlib
import copy
import hashlib
import importlib
import io
import json
from pathlib import Path
import shlex
import sys
import tempfile
from types import ModuleType, SimpleNamespace
import unittest
from unittest.mock import patch
import launch_remote_solo_prefill as launcher
from prefill_compute_archive import digest, write_json
from prefill_compute_contract import configuration, parse, validate_first, validate_final
from prefill_compute_inputs import ARTIFACT, CONFIGURATION, VOCABULARY, expected_frames, recorded_fingerprint
from remote_prefill_client import RemoteControl, RemoteMemoryGate, prepare_controls, upload_new, create_remote
from remote_prefill_paths import ABSENT, BOOTSTRAP, PINNED_RUNNER, absolute_path, host_alias, paths
from remote_prefill_supervision import supervise
from solo_prefill_reference import BASELINE_EVIDENCE_SHA256, worker_bytes, rank_input_order

PROMPT, RUN_ID = [3] * 65, 'a' * 32
REQUEST_ID = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'


def reference():
    source = dict(artifactAggregateSHA256=ARTIFACT, sourceConfigurationSHA256=CONFIGURATION,
        bf16ConversionEnabled=True, embeddingActivationDType='bfloat16', layerCount=32,
        vocabularySize=VOCABULARY, planSHA256='c' * 64,
        sourceModelTensorBytes=5038041600, sourceParameterLayoutSHA256='d' * 64)
    descriptor = rank_input_order(dict(source=source))
    return dict(descriptor=descriptor, source=source,
        staged_file_sha256=hashlib.sha256(worker_bytes(descriptor)).hexdigest(),
        baseline_evidence_sha256=BASELINE_EVIDENCE_SHA256, files=[])


def fixture():
    ref = reference()
    request = dict(request=dict(requestID=REQUEST_ID, promptCount=65, chunkSize=32, outputCount=1),
        vocabularySize=VOCABULARY, promptTokenIDs=PROMPT, teacherTokenIDs=[],
        fingerprint=recorded_fingerprint(REQUEST_ID, PROMPT),
        steps=[dict(frame=f, tokenIDs=PROMPT[f['tokenOffset']:f['tokenOffset'] + f['tokenCount']]) for f in expected_frames()])
    first = dict(kind='qwen_layer_stage_solo_prefill_ready', schemaVersion=1,
        verifiedModelLoaded=True, freshRequestStateCreated=False,
        referenceFileSHA256=ref['staged_file_sha256'], baselineEvidenceFingerprint=BASELINE_EVIDENCE_SHA256,
        request=request, source=ref['source'])
    last = dict(kind='qwen_layer_stage_solo_prefill_report', schemaVersion=1, correctnessOnly=True,
        throughputMeasurementValid=False, completed=True, interprocessTransportUsed=False,
        physicalTransferQualified=False, allRequestStateRetired=True, modelReleased=True,
        conservativeStateAndBoundaryBytes=53641248, memory=[{}] * 4,
        execution=dict(opaqueNativeSoloExecution=True))
    return first, last


class Child:
    pid = 7001
    def __init__(self, code):
        self.code, self.waits = code, 0
    def poll(self):
        return self.code
    def wait(self, timeout):
        assert self.code is not None
        self.waits += 1
        return self.code


class Tests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name).resolve()
        for name in ('subprocess.run', 'subprocess.Popen', 'socket.socket'):
            guard = patch(name, side_effect=AssertionError('Real process/socket creation forbidden'))
            guard.start()
            self.addCleanup(guard.stop)

    def test_host_and_remote_path_admission(self):
        self.assertEqual(host_alias('fixture-peer'), 'fixture-peer')
        for value in ('-oProxyCommand=x', 'x y', 'x;id', 'user@host', 'x\n', '', 'x:$()'):
            with self.assertRaises(ValueError): host_alias(value)
        for value in ('relative', '/x/../y', '/x y', '/x//y', '/x/./y', '/x;touch', '/x/$(id)'):
            with self.assertRaises(ValueError): absolute_path(value)

    def test_layout_is_unique_and_separate_from_model(self):
        value = paths('/Users/fixture', None, '/Users/developer/models/model', RUN_ID)
        self.assertEqual(value['native'], '/Users/developer/DarkbloomDev/cluster-runs/' + RUN_ID + '/native')
        with self.assertRaises(ValueError): paths('/Users/fixture', '/models', '/models/model', RUN_ID)

    def test_exclusive_bootstrap_and_upload_absence(self):
        root = self.path / 'runs'
        with patch.object(sys, 'argv', ['bootstrap', str(root), RUN_ID]), contextlib.redirect_stdout(io.StringIO()):
            exec(BOOTSTRAP, {})
            with self.assertRaises(FileExistsError): exec(BOOTSTRAP, {})
        target = root / RUN_ID / 'native'
        with patch.object(sys, 'argv', ['absent', str(target)]):
            with self.assertRaises(ValueError): exec(ABSENT, {})

    def test_create_remote_and_scp_use_argument_vectors(self):
        calls = []
        def ssh(host, args, **kwargs):
            calls.append((host, args, kwargs))
            return SimpleNamespace(stdout='/Users/fixture\n' if len(calls) == 1 else '/Users/developer/DarkbloomDev/cluster-runs/' + RUN_ID + '\n')
        processes = SimpleNamespace(ssh=ssh, scp=lambda source, destination: calls.append(('scp', source, destination)))
        value = create_remote(processes, 'fixture-peer', '/models/fixture', None, RUN_ID)
        upload_new(processes, 'fixture-peer', self.path / 'local', value['controls'])
        self.assertEqual(calls[-2][1][:3], ['/usr/bin/python3', '-c', ABSENT])
        self.assertEqual(calls[-1][2], 'fixture-peer:' + shlex.quote(value['controls']))

    def test_solo_arguments_and_outer_contract(self):
        c = configuration('/remote/native/bundle', 'b' * 64, '/models/fixture', PROMPT, 180, reference())
        for flag in ('--transport', '--epoch', '--teacher-tokens-file'):
            self.assertNotIn(flag, c['arguments'])
        self.assertEqual(c['environment'], {'DARKBLOOM_BF16_WEIGHTS': '1'})
        a, b = fixture()
        validate_first(a, PROMPT, reference())
        validate_final(b, a)
        b['modelReleased'] = False
        with self.assertRaises(ValueError): validate_final(b, a)

    def test_old_schema_wrong_source_history_and_json_fail_closed(self):
        for mutate in (lambda x: x['source'].update(artifactAggregateSHA256='f' * 64),
                       lambda x: x['request'].update(teacherTokenIDs=[1]),
                       lambda x: x['request'].update(fingerprint='f' * 64)):
            first, _ = fixture(); mutate(first)
            with self.assertRaises(ValueError): validate_first(first, PROMPT, reference())
        for raw in ('{"x":1,"x":2}', '[NaN]', '[1e999]'):
            with self.assertRaises(ValueError): parse(raw)

    def test_controls_are_pinned_before_executing_imports(self):
        controls = self.path / 'controls'; controls.mkdir()
        contents = {'remote_prefill_control.py': 'pass\n', 'prefill_compute_memory.py': '# fixture\n',
                    'artifacts.py': '# fixture\n', 'control-config.json': '{}\n'}
        for name, content in contents.items(): (controls / name).write_text(content)
        manifest = controls / 'control-manifest.json'
        write_json(manifest, dict(files=[dict(path=p.name, size_bytes=p.stat().st_size, sha256=digest(p)) for p in sorted(controls.iterdir())]))
        arguments = ['runner', str(manifest), digest(manifest), 'initial']
        with patch.object(sys, 'argv', arguments[:]), patch.object(sys, 'path', sys.path[:]): exec(PINNED_RUNNER, {})
        (controls / 'artifacts.py').write_text('# altered\n')
        with patch.object(sys, 'argv', arguments[:]), patch.object(sys, 'path', sys.path[:]):
            with self.assertRaises(ValueError): exec(PINNED_RUNNER, {})

    def test_control_manifest_hash_mismatch_does_not_execute(self):
        manifest = self.path / 'manifest.json'; manifest.write_text('{}')
        with patch.object(sys, 'argv', ['runner', str(manifest), 'b' * 64, 'initial']):
            with self.assertRaises(ValueError): exec(PINNED_RUNNER, {})

    def make_client(self, mutate=lambda x: None):
        layout = paths('/Users/fixture', None, '/models/fixture', RUN_ID)
        calls = []
        def ssh(host, args, **kwargs):
            calls.append((host, args, kwargs))
            value = dict(kind='remote_prefill_control', schema_version=1, operation=args[-1],
                         run_id=RUN_ID, remote_run=layout['run'], result=dict(passed=True))
            mutate(value)
            return SimpleNamespace(stdout=json.dumps(value), stderr='')
        client = RemoteControl(SimpleNamespace(ssh=ssh), 'fixture-peer', layout, RUN_ID, 'b' * 64, self.path)
        return client, calls

    def test_remote_control_calls_are_pinned_and_saved(self):
        client, calls = self.make_client()
        self.assertTrue(client.call('initial', timeout=3)['passed'])
        self.assertEqual(calls[0][1][2], PINNED_RUNNER)
        self.assertEqual(calls[0][1][-2:], ['b' * 64, 'initial'])
        self.assertEqual(calls[0][2]['timeout'], 3)
        self.assertTrue((self.path / 'remote-observations/0001-initial.json').is_file())

    def test_remote_control_wrong_epoch_is_saved_and_rejected(self):
        client, _ = self.make_client(lambda x: x.update(run_id='c' * 32))
        with self.assertRaises(ValueError): client.call('before')
        self.assertFalse(client.calls[0]['passed'])

    def test_remote_memory_retains_failure_and_requires_zero_new_swap(self):
        gate = RemoteMemoryGate()
        base = dict(pressure_level=1, swap_used_bytes='0', remote_pid_inventory=dict(observed_processes=[]))
        gate.consume(base)
        with self.assertRaises(ValueError): gate.consume(dict(base, swap_used_bytes='104857.6'))
        self.assertEqual(len(gate.samples), 2)
        with self.assertRaises(ValueError): RemoteMemoryGate().consume(dict(base, pressure_level=3))

    def test_remote_initial_refusal_precedes_bundle_upload_or_model_hash(self):
        runtime = self.path / 'repo/experiments/cluster/runtime'; runtime.mkdir(parents=True)
        release = self.path / 'release'; release.mkdir()
        origin = self.path / 'origin'; origin.mkdir()
        inventory = self.path / 'inventory.json'; inventory.write_text('{}')
        output = self.path / 'output'; uploads, operations = [], []
        binary = b'non-executable CPU fixture'
        def snapshot(source, destination):
            destination.mkdir()
            (destination / 'cluster-inference').write_bytes(binary)
            (destination / 'artifacts.py').write_text('# CPU fixture\n')
            write_json(destination / 'bundle.json', dict(files=[dict(path=p.name, sha256=digest(p)) for p in destination.iterdir()]))
            return digest(destination / 'bundle.json')
        def archive(source, destination):
            write_json(destination / 'source-manifest.json', dict(files=[]))
            return dict(files=[])
        class RefusedControl:
            def __init__(self, *args): pass
            def call(self, operation, timeout):
                operations.append(operation)
                if operation != 'initial': raise AssertionError('Remote model hash occurred after refusal')
                return dict(passed=False, actual_free_bytes=5 * 1024**3)
        layout = paths('/Users/fixture', None, '/models/fixture', RUN_ID)
        args = ['--release', str(release), '--runtime', str(runtime), '--output', str(output),
                '--input-origin', str(origin), '--expected-inventory', str(inventory), '--host', 'fixture-peer',
                '--remote-model-dir', '/models/fixture', '--artifact-aggregate-sha256', ARTIFACT,
                '--expected-native-sha256', hashlib.sha256(binary).hexdigest(),
                '--solo-reference', str(self.path / 'reference.json')]
        modules = dict(bundle=SimpleNamespace(snapshot=snapshot), processes=SimpleNamespace())
        with patch.object(launcher, 'archive_launcher', return_value=[]), patch.object(launcher, 'archive_sources', side_effect=archive), \
             patch.object(launcher, 'load_archived_runtime', return_value=modules), patch.object(launcher, 'verify_archive'), \
             patch.object(launcher, 'archive_inputs', return_value=dict(prompt=PROMPT, teacher=[], files=[])), \
             patch.object(launcher, 'archive_reference', return_value=reference()), \
             patch.object(launcher, 'verify_rank_serialization'), \
             patch.object(launcher, 'create_remote', return_value=layout), patch.object(launcher, 'RemoteControl', RefusedControl), \
             patch.object(launcher, 'upload_new', side_effect=lambda *args: uploads.append(args[-1])), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(launcher.main(args), 1)
        self.assertEqual(operations, ['initial'])
        self.assertEqual(uploads, [layout['controls']])
        receipt = json.loads((output / 'receipt.json').read_text())
        self.assertFalse(receipt['native_execution_attempted'])
        self.assertFalse(receipt['local_model_payload_verified'])
        self.assertEqual(receipt['remote_initial_free_screen']['actual_free_bytes'], 5 * 1024**3)

    def test_remote_pid_matching_preserves_sampled_rss(self):
        fake = ModuleType('artifacts')
        fake.file_sha256, fake.verify_files, fake.verify_model = digest, None, None
        with patch.dict(sys.modules, {'artifacts': fake}):
            control = importlib.import_module('remote_prefill_control')
        config = dict(bundle='/runs/owned/native/bundle', native='/runs/owned/native')
        text = '12 1 12 123 /runs/owned/native/bundle/cluster-inference --mode x\n'
        text += '11 1 11 45 /usr/bin/python3 /runs/owned/native/bundle/rank_worker.py /runs/owned/native/rank.json\n'
        text += '13 1 13 999 /runs/other/native/bundle/cluster-inference --mode x\n'
        record = control.parse_process_inventory(text, config)
        self.assertEqual([x['rssBytes'] for x in record['observed_processes']], [123 * 1024, 45 * 1024])
        self.assertEqual([x['kind'] for x in record['observed_processes']], ['native', 'supervisor'])
        self.assertTrue(record['missing_process_rss_is_not_assumed_zero'])
        self.assertEqual(control.parse_process_inventory('', config)['observed_processes'], [])

    def run_fake(self, code, rows, memory=lambda seconds: None):
        child, clock, stops = Child(code), [0], []
        rank = dict(rank=0, host='fixture-peer', local=str(self.path), directory='/runs/owned/native')
        def start(value):
            self.assertEqual(value['host'], 'fixture-peer')
            (self.path / 'stdout.jsonl').write_text(''.join(json.dumps(row) + '\n' for row in rows))
            return child
        def stop(ranks, children):
            stops.append((ranks, children))
            if child.code is None: child.code = -15
        def sleep(seconds): clock[0] += seconds
        result = supervise(rank, PROMPT, reference(), 1, start, stop, memory, lambda: clock[0], sleep)
        return result, child, stops

    def test_success_labels_local_ssh_pid_without_remote_reap_claim(self):
        result, child, stops = self.run_fake(0, fixture())
        self.assertTrue(result['passed']); self.assertFalse(stops)
        self.assertEqual(result['local_ssh_client_pid'], 7001)
        self.assertNotIn('supervisor_pid', result)
        self.assertFalse(result['remote_process_reaping_independently_verified'])
        self.assertEqual(child.waits, 1)

    def test_eof_without_final_fails_and_requests_remote_cancel(self):
        result, _, stops = self.run_fake(0, [fixture()[0]])
        self.assertFalse(result['passed']); self.assertTrue(stops)

    def test_dead_ssh_client_still_requests_owned_remote_cancel(self):
        result, child, stops = self.run_fake(255, [])
        self.assertEqual(result['exit_code'], 255)
        self.assertTrue(stops); self.assertEqual(child.waits, 1)

    def test_parent_deadline_bounds_remote_observation_timeout(self):
        deadlines = []
        result, _, stops = self.run_fake(None, [], lambda seconds: deadlines.append(seconds))
        self.assertEqual(result['cancellation_reason'], 'local_parent_deadline')
        self.assertTrue(stops); self.assertTrue(all(0 < x <= 1 for x in deadlines))

    def test_memory_and_wrong_record_failures_cancel_owned_remote_run(self):
        def failed(seconds): raise ValueError('remote pressure')
        result, _, stops = self.run_fake(None, [], failed)
        self.assertFalse(result['passed']); self.assertTrue(stops)
        result, _, stops = self.run_fake(None, [fixture()[1]])
        self.assertFalse(result['passed']); self.assertTrue(stops)

    def test_remote_identity_requires_exact_bundle_and_rank(self):
        config = dict(bundle_sha256='b' * 64, rank_sha256='c' * 64)
        value = dict(artifact_aggregate_sha256=ARTIFACT, bundle_manifest_sha256='b' * 64,
                     bundle_file_sha256={'x': 'e' * 64}, rank_configuration_sha256='c' * 64,
                     model_metadata={'config.json': dict(sha256=CONFIGURATION)})
        launcher.verified_remote(value, config, {'x': 'e' * 64})
        value['bundle_file_sha256']['extra'] = 'f' * 64
        with self.assertRaises(ValueError): launcher.verified_remote(value, config, {'x': 'e' * 64})


if __name__ == '__main__':
    unittest.main()
