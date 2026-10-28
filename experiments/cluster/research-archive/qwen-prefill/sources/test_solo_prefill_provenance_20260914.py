"""Prospective CPU/fake checks; no native, process, socket or model payload IO."""
from contextlib import redirect_stdout
import copy
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import shlex
import socket
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import solo_prefill_provenance_records as records
from solo_prefill_provenance_archive import archive_files, pure_helpers


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module


POST = load('prospective_solo_postflight', 'postflight-remote-solo-prefill-20260914.py')
VERIFY = load('prospective_solo_verifier', 'verify-remote-solo-prefill-provenance-20260914.py')


def fixture_receipt():
    run_id = '1' * 32
    root = '/tmp/owned-runs'; run = root + '/' + run_id
    remote = dict(root=root, run=run, native=run + '/native', controls=run + '/controls',
                  bundle=run + '/native/bundle', model='/tmp/model')
    return dict(kind='remote_qwen_layer_stage_solo_prefill_launcher', schema_version=1,
        run_id=run_id, execution_host='fixture-host', remote_paths=remote,
        passed=True, native_execution_attempted=True, native_process_count=1, timeout_seconds=180,
        source_bundle_inputs_and_remote_model_unchanged_after_run=True,
        remote_pid_observations_are_not_reaping_proof=True, physical_two_machine_execution=False,
        interprocess_model_transport=False, throughput_qualification=False,
        independent_comparison_oracle_run=False, local_model_payload_verified=False,
        native_baseline_forward=False, primary_failure=None, cleanup_errors=[], post_run_errors=[],
        bundle_manifest_sha256='a' * 64, inputs=dict(prompt=list(range(65)), teacher=[]),
        execution=dict(passed=True, exit_code=0, local_ssh_client_reaped=True, local_ssh_client_pid=123,
            remote_process_reaping_independently_verified=False, independent_comparison_oracle_run=False,
            validated_outer_records=2, error=None, cancellation_reason=None, cleanup_errors=[]))


def fixture_reference(prompt):
    value = dict(extra='fixture/\u03bb', request=dict(promptTokenIDsSHA256=hashlib.sha256(','.join(map(str,prompt)).encode()).hexdigest(),
        promptCount=65, chunkSize=32, outputCount=1, vocabularySize=248320),
        source=dict(sourceConfigurationSHA256=records.CONFIGURATION, artifactAggregateSHA256=records.ARTIFACT),
        baselineEvidenceFingerprint=records.BASELINE_EVIDENCE)
    raw = (json.dumps(value, ensure_ascii=False, indent=2) + '\n').encode()
    staged = json.dumps(json.loads(json.dumps(value, sort_keys=True))).encode('ascii')
    reference = dict(origin_file_sha256=hashlib.sha256(raw).hexdigest(),
        staged_file_sha256=hashlib.sha256(staged).hexdigest(), baseline_evidence_sha256=records.BASELINE_EVIDENCE,
        original_and_staged_bytes_identical=False, native_baseline_forward_required=False,
        worker_serialization='json.dumps(content), default separators/ensure_ascii, no newline')
    return value, raw, staged, reference


class SoloProvenanceTests(unittest.TestCase):
    def setUp(self):
        self.guards = [patch.object(subprocess, name, side_effect=AssertionError('No actual process creation'))
                       for name in ('run', 'Popen')]
        self.guards.append(patch.object(socket, 'socket', side_effect=AssertionError('No sockets')))
        for guard in self.guards: guard.start(); self.addCleanup(guard.stop)

    def test_completion_and_layout_scope(self):
        value = fixture_receipt()
        self.assertEqual(records.validate_completion(value)['local_ssh_client_pid'], 123)
        for key in ('passed', 'source_bundle_inputs_and_remote_model_unchanged_after_run'):
            broken = copy.deepcopy(value); broken[key] = False
            with self.subTest(key=key), self.assertRaises(ValueError): records.validate_completion(broken)

    def test_rejects_cleanup_errors_and_false_reaping_claim(self):
        for key, changed in [('cleanup_errors', ['failed']), ('post_run_errors', ['failed']),
                             ('primary_failure', {'operation':'failed'}), ('native_baseline_forward', True)]:
            value = fixture_receipt(); value[key] = changed
            with self.subTest(key=key), self.assertRaises(ValueError): records.validate_completion(value)
        value = fixture_receipt(); value['execution']['remote_process_reaping_independently_verified'] = True
        with self.assertRaises(ValueError): records.validate_completion(value)

    def test_path_and_host_injection_rejected_before_invocation(self):
        for key, changed in [('execution_host', '-oBad'), ('run_id', '../other')]:
            value = fixture_receipt(); value[key] = changed
            with self.subTest(key=key), self.assertRaises(ValueError): POST.observe(value, lambda *a, **k: self.fail('invoked'))
        for path in ('/tmp/owned-runs/../elsewhere', '/tmp/model', '/tmp/space path'):
            value = fixture_receipt(); value['remote_paths']['run'] = path
            with self.subTest(path=path), self.assertRaises(ValueError): records.validate_layout(value)

    def test_default_worker_reference_bytes_not_origin_bytes(self):
        prompt = fixture_receipt()['inputs']['prompt']; value, raw, staged, ref = fixture_reference(prompt)
        with patch.object(records, 'ORIGIN_REFERENCE', ref['origin_file_sha256']):
            ordered, result, pin = records.reference_bytes(raw, value, prompt, ref)
        self.assertEqual(result, staged); self.assertNotEqual(result, raw)
        self.assertEqual(pin, hashlib.sha256(staged).hexdigest())
        self.assertEqual(json.dumps(ordered).encode('ascii'), staged)

    def test_origin_staged_and_baseline_pins_fail_closed(self):
        prompt = fixture_receipt()['inputs']['prompt']; value, raw, _, ref = fixture_reference(prompt)
        with patch.object(records, 'ORIGIN_REFERENCE', ref['origin_file_sha256']):
            for key in ('origin_file_sha256','staged_file_sha256','baseline_evidence_sha256'):
                changed = dict(ref, **{key: '0' * 64})
                with self.subTest(key=key), self.assertRaises(ValueError): records.reference_bytes(raw, value, prompt, changed)
            with self.assertRaises(ValueError): records.reference_bytes(raw + b' ', value, prompt, ref)

    def test_exact_three_reference_flags_and_no_transport(self):
        receipt = fixture_receipt(); descriptor, _, _, _ = fixture_reference(receipt['inputs']['prompt'])
        rank = records.expected_rank(receipt, descriptor, 'b' * 64)
        args = rank['arguments']
        expected = {'--solo-reference-file':'@rank/solo-reference.json', '--solo-reference-sha256':'b' * 64,
                    '--solo-baseline-evidence-sha256':records.BASELINE_EVIDENCE}
        for flag, value in expected.items():
            self.assertEqual(args.count(flag), 1); self.assertEqual(args[args.index(flag)+1], value)
        self.assertNotIn('--transport', args); self.assertNotIn('--epoch', args)
        self.assertEqual(args[args.index('--decode-tokens')+1], '1')

    def test_postflight_fake_invocation_is_shell_quoted(self):
        receipt = fixture_receipt(); calls = []
        observation = dict(remoteRun=receipt['remote_paths']['run'], ownedLiveProcesses=[])
        def fake(args, **kwargs):
            calls.append((args, kwargs)); return SimpleNamespace(returncode=0, stdout=json.dumps(observation), stderr='')
        result = POST.observe(receipt, fake)
        self.assertTrue(result['passed']); self.assertEqual(len(calls), 1)
        argv = shlex.split(calls[0][0][-1])
        self.assertEqual(argv[:2], ['/usr/bin/python3','-c'])
        self.assertEqual(argv[2], POST.REMOTE); self.assertEqual(json.loads(argv[3]), receipt['remote_paths'])
        self.assertEqual(calls[0][1]['timeout'], 20)

    def test_postflight_live_owned_process_and_ssh_failure_fail(self):
        receipt = fixture_receipt()
        for code, rows, stderr in [(0,[{'pid':99}],''), (255,[],''), (0,[],'warning')]:
            observation = dict(remoteRun=receipt['remote_paths']['run'], ownedLiveProcesses=rows)
            fake = lambda *a, **k: SimpleNamespace(returncode=code, stdout=json.dumps(observation), stderr=stderr)
            with self.subTest(code=code,rows=rows,stderr=stderr): self.assertFalse(POST.observe(receipt,fake)['passed'])

    def test_remote_parser_with_fake_reads_preserves_rss_and_scope(self):
        layout = fixture_receipt()['remote_paths']; binary = layout['bundle'] + '/cluster-inference'
        raw = '\n'.join(['101 100 101 2048 ' + binary + ' --tokens-file ' + layout['native'] + '/prompt.json',
            '100 1 100 64 /usr/bin/python3 ' + layout['bundle'] + '/rank_worker.py ' + layout['native'] + '/rank.json',
            '303 1 303 999 ' + binary + '-other --mode ignored'])
        calls = []
        def fake(args, **kwargs):
            calls.append(args)
            text = raw if args[0] == '/bin/ps' else 'fixture metadata\n'
            return SimpleNamespace(stdout=text, stderr='', returncode=0)
        output = io.StringIO()
        with patch.object(subprocess, 'run', side_effect=fake), patch.object(sys, 'argv', ['remote',json.dumps(layout)]), redirect_stdout(output):
            exec(compile(POST.REMOTE, '<fixed read-only remote script>', 'exec'), {})
        result = json.loads(output.getvalue()); rows = result['ownedLiveProcesses']
        self.assertEqual([(r['kind'],r['pid'],r['rssBytes']) for r in rows], [('native',101,2048*1024),('supervisor',100,64*1024)])
        self.assertEqual(len(calls), 5); self.assertEqual(result['remoteRun'],layout['run'])

    def test_prior_pure_helpers_and_archive_escape_rejection(self):
        helper = pure_helpers()
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); base = root/'archive'; base.mkdir(); outside = root/'outside'; outside.write_bytes(b'fixture')
            item = dict(path='../outside',sha256=helper.sha(outside),size_bytes=7)
            with self.assertRaises(ValueError): archive_files(helper,base,[item])
            malformed = root/'duplicate.json'; malformed.write_text('{"a":1,"a":2}')
            with self.assertRaises(ValueError): helper.read(malformed)

    def test_postflight_source_and_receipt_fingerprints_required(self):
        h = pure_helpers(); receipt = fixture_receipt()
        with tempfile.TemporaryDirectory() as temp:
            receipt['_audit_run'] = temp
            source = Path(temp)/'source/experiments/cluster/runtime'; source.mkdir(parents=True)
            for name in ('rank_worker.py','processes.py'): (source/name).write_text('# fixture only\n')
            value = dict(kind='root_remote_solo_prefill_postflight',schemaVersion=1,passed=True,
                launcherReceiptSHA256='a'*64,scriptSHA256=h.sha(Path(POST.__file__)),
                helperSHA256=h.sha(Path(records.__file__)),runID=receipt['run_id'],nativeBinarySHA256=records.BINARY,
                localSSHClientPID=123,localSSHClientReaped=True,remoteReapingIndependentlyProven=False,
                remoteWorkerCleanupSourceBound=True,rootLauncherTerminalExitCode=0,sshExitCode=0,sshStderr='',
                cleanupSourceSHA256={name:h.sha(source/name) for name in ('rank_worker.py','processes.py')},
                observation=dict(ownedLiveProcesses=[],remoteRun=receipt['remote_paths']['run'],
                    timestampUTC='2026-09-14T00:00:00+00:00',memory='1\nused = 0.00M\n',pythonVersion='fixture'))
            resources = dict(reportedSwapBaselineBytes='0')
            self.assertEqual(VERIFY.validate_postflight(value,receipt,'a'*64,resources,h)['pressureLevel'],1)
            for key in ('launcherReceiptSHA256','scriptSHA256','helperSHA256'):
                changed=dict(value,**{key:'0'*64})
                with self.subTest(key=key),self.assertRaises(ValueError):
                    VERIFY.validate_postflight(changed,receipt,'a'*64,resources,h)

    def test_postflight_metadata_refusal_never_creates_a_process(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp); (root/'receipt.json').write_text(json.dumps(fixture_receipt()))
            output=root/'new-postflight.json'
            with self.assertRaises(ValueError):
                POST.main([str(root),'--receipt-sha256','0'*64,'--root-launcher-exit-code','0',
                           '--output',str(output)],invoke=lambda *a,**k:self.fail('Invoked before admission'))
            self.assertFalse(output.exists())


if __name__ == '__main__':
    unittest.main()
