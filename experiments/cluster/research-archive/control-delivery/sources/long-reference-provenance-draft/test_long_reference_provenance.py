"""Prospective mutations of invented archives; actual candidate stays unread."""
import copy
from dataclasses import replace
import json
from pathlib import Path
import shlex
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from long_reference_provenance_common import files, parse, read, sha
from long_reference_provenance_records import validate_completion, validate_layout
from provenance_fixture import make_fixture, write
from verify_long_reference_provenance import validate, validate_postflight
from postflight_remote_long_reference import observe, main as postflight_main


class Tests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(); self.addCleanup(temp.cleanup)
        self.root = Path(temp.name).resolve()
        for name in ('subprocess.run', 'subprocess.Popen', 'socket.socket'):
            guard = patch(name, side_effect=AssertionError('Real process/socket forbidden'))
            guard.start(); self.addCleanup(guard.stop)
        self.f = make_fixture(self.root)

    def audit(self, **changes):
        f = self.f
        args = dict(run=f.run, receipt_sha=sha(f.run / 'receipt.json'), pins=f.pins,
                    review_path=f.review, review_sha=f.review_sha, origin_directory=f.origin,
                    postflight_path=f.postflight, postflight_sha=sha(f.postflight))
        args.update(changes)
        return validate(**args)

    def test_complete_invented_archive_passes_without_live_tree_or_numerical_reads(self):
        result = self.audit()
        self.assertEqual(result['status'], 'passed'); self.assertFalse(result['liveRepositoryCompared'])
        self.assertTrue(result['workload']['exactRawOriginLocalAndRemotePromptBytes'])
        self.assertFalse(result['workload']['nativeOutputJSONParsed'])
        self.assertEqual(result['resources']['samples'], 3)
        self.assertIsNone(result['resources']['maximumSampledNativeRSSBytes'])

    def test_explicit_native_prompt_origin_and_review_pins_refuse(self):
        for key in ('native', 'prompt', 'origin', 'configuration', 'artifact'):
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.audit(pins=replace(self.f.pins, **{key: '0' * 64}))
        with self.assertRaises(ValueError): self.audit(review_sha='0' * 64)

    def test_archived_source_bundle_and_launcher_drift_refuse(self):
        for path in ['source/experiments/cluster/runtime/rank_worker.py', 'bundle/cluster-inference',
                     'launcher/remote_prefill_control.py', 'controls/control-config.json']:
            file = self.f.run / path; original = file.read_bytes(); file.write_bytes(original + b' ')
            with self.subTest(path=path), self.assertRaises(ValueError): self.audit()
            file.write_bytes(original)

    def test_raw_prompt_reencoding_and_origin_source_changes_refuse(self):
        for file in [self.f.run / 'remote-metadata/prompt.final.json', self.f.origin / 'source-text.txt']:
            original = file.read_bytes(); file.write_bytes(original + b' ')
            with self.subTest(file=file.name), self.assertRaises(ValueError): self.audit()
            file.write_bytes(original)

    def test_old_mode_deadline_and_cleanup_claims_refuse(self):
        receipt = read(self.f.run / 'receipt.json')
        for key, value in [('kind', 'remote_qwen_layer_stage_solo_prefill_launcher'),
                           ('native_timeout_seconds', 180), ('parent_timeout_seconds', 331),
                           ('cleanup_errors', ['failed']), ('stage_model_forward_requested', True)]:
            wrong = dict(receipt, **{key: value})
            with self.subTest(key=key), self.assertRaises(ValueError): validate_completion(wrong, self.f.pins)
        wrong = copy.deepcopy(receipt); wrong['execution']['remote_process_reaping_independently_verified'] = True
        with self.assertRaises(ValueError): validate_completion(wrong, self.f.pins)

    def test_control_replay_and_resource_claim_mutation_refuse(self):
        path = self.f.run / 'remote-observations/0003-observe.json'; original = path.read_bytes()
        record = read(path); record['record']['run_id'] = '4' * 32; write(path, record)
        with self.assertRaises(ValueError): self.audit()
        path.write_bytes(original)
        path = self.f.run / 'receipt.json'; record = read(path)
        record['remote_initial_free_screen']['actual_free_bytes'] += 1; write(path, record)
        with self.assertRaises(ValueError): self.audit()

    def test_nonzero_swap_is_rejected_even_when_unchanged(self):
        receipt = read(self.f.run / 'receipt.json')
        for sample in receipt['remote_memory_samples']:
            sample.update(swap_used_bytes='1048576', raw_sysctl='1\nused = 1.00M\n')
        receipt['remote_before']['memory'] = copy.deepcopy(receipt['remote_memory_samples'][0])
        receipt['remote_after']['memory'] = copy.deepcopy(receipt['remote_memory_samples'][-1])
        write(self.f.run / 'receipt.json', receipt)
        for name, value in [('0002-before.json', receipt['remote_before']),
                            ('0003-observe.json', receipt['remote_memory_samples'][1]),
                            ('0004-after.json', receipt['remote_after'])]:
            path = self.f.run / 'remote-observations' / name; record = read(path)
            record['record']['result'] = value; write(path, record)
        with self.assertRaises(ValueError): self.audit()

    def test_archive_escape_symlink_duplicate_and_json_duplicate_refuse(self):
        outside = self.root / 'outside'; outside.write_bytes(b'x')
        for path in ('../outside', '/outside'):
            with self.assertRaises(ValueError): files(self.f.run, [dict(path=path, size_bytes=1, sha256=sha(outside))])
        link = self.f.run / 'link'; link.symlink_to(outside)
        with self.assertRaises(ValueError): files(self.f.run, [dict(path='link', size_bytes=1, sha256=sha(outside))])
        for raw in ('{"x":1,"x":2}', '{"x":1,"\\u0078":2}', '[NaN]', '[1e999]'):
            with self.assertRaises(ValueError): parse(raw)

    def test_oversized_native_output_is_not_a_success_receipt(self):
        path = self.f.run / 'native/stdout.jsonl'
        with path.open('wb') as stream: stream.truncate(8 * 1024**2 + 1)
        with self.assertRaises(ValueError): self.audit()

    def test_fake_postflight_quotes_only_owned_paths_and_has_explicit_timeout(self):
        receipt, calls = read(self.f.run / 'receipt.json'), []
        def invoke(arguments, **kwargs):
            calls.append((arguments, kwargs))
            return SimpleNamespace(returncode=0, stderr='', stdout=json.dumps(dict(
                remoteRun=receipt['remote_paths']['run'], ownedLiveProcesses=[])))
        self.assertTrue(observe(receipt, invoke)['passed'])
        argv = shlex.split(calls[0][0][-1])
        self.assertEqual(argv[:2], ['/usr/bin/python3', '-c'])
        self.assertEqual(json.loads(argv[3]), receipt['remote_paths']); self.assertEqual(calls[0][1]['timeout'], 20)
        for host in ('-oUnsafe', 'peer with space'):
            with self.assertRaises(ValueError): observe(dict(receipt, execution_host=host), lambda *a, **k: self.fail('Invoked'))

    def test_postflight_owned_process_stderr_wrong_identity_and_receipt_pin_refuse(self):
        receipt = read(self.f.run / 'receipt.json')
        for code, rows, stderr in [(0, [dict(pid=1)], ''), (255, [], ''), (0, [], 'warning')]:
            def invoke(*args, **kwargs):
                return SimpleNamespace(returncode=code, stderr=stderr, stdout=json.dumps(dict(
                    remoteRun=receipt['remote_paths']['run'], ownedLiveProcesses=rows)))
            self.assertFalse(observe(receipt, invoke)['passed'])
        with self.assertRaises(ValueError): postflight_main([str(self.f.run), '--receipt-sha256', '0' * 64,
            '--expected-native-sha256', self.f.pins.native, '--root-launcher-exit-code', '0',
            '--output', str(self.root / 'never.json')], invoke=lambda *a, **k: self.fail('Invoked'))

    def test_postflight_source_pins_and_scope_are_required(self):
        record, receipt = read(self.f.postflight), read(self.f.run / 'receipt.json')
        for key, value in [('nativeBinarySHA256', '0' * 64), ('liveRepositoryCompared', True),
                           ('remoteReapingIndependentlyProven', True), ('sshExitCode', False)]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                validate_postflight(dict(record, **{key: value}), receipt, sha(self.f.run / 'receipt.json'), self.f.pins.native, self.f.run)


if __name__ == '__main__': unittest.main()
