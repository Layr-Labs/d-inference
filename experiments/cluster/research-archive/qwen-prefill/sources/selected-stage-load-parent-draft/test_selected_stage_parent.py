import copy
import hashlib
import json
from pathlib import Path
import socket
import tempfile
import types
import unittest
from unittest.mock import patch

import stage_load_contract as contract
import run_selected_stage_load as parent


PROFILE = 'registered_qwen35_9b'
BATTERY = "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1)\t19%; discharging; 1:00 remaining present: true\n"
AC = "Now drawing from 'AC Power'\n"


def sample(pid=None, executable=None):
    result = dict(actualFreeBytes=8 * contract.GIB, pressureLevel=1, reportedSwapBytes='0.00',
                  nativeRSSBytes=None, missingRSSIsNotZero=True)
    if pid is not None:
        result.update(nativePID=pid, nativePGID=pid, nativeRSSBytes=3 * contract.GIB,
                      nativeCommand=str(executable) + ' --mode qwen-dense-stage-load-check --model-dir /fake')
    return result


def result(stage=0, profile=PROFILE):
    row = {key: True for key in contract.TRUE_FLAGS}
    row.update({key: False for key in contract.FALSE_FLAGS})
    row.update(kind='qwen_dense_stage_load_report', schemaVersion=1, model=profile, stageIndex=stage,
        profileFingerprint='a' * 64, arithmeticEnvironment={}, initialResources={},
        loadingResources=[], releasedResources={}, memory=[], runtime={},
        selectedStageModelsLoaded=1, fullCheckpointVerificationPasses=1,
        load=dict(schemaVersion=1, stageIndex=stage, verifiedAggregateSHA256=contract.PROFILES[profile]['artifact'],
                  sourceConfigurationSHA256=contract.PROFILES[profile]['configuration'],
                  bf16ConversionEnabled=True, planSHA256='b' * 64),
        budget=dict(model=profile, stageIndex=stage, profileFingerprint='a' * 64,
                    planFingerprint='b' * 64, resourceAdmissionPerformed=False, forwardExecutionAuthorized=False))
    return row


def raw(row):
    return json.dumps(row, separators=(',', ':')).encode() + b'\n'


class FakeProcess:
    pid = 91234
    def __init__(self, code=0):
        self.returncode = None
        self.code = code
        self.waits = 0
    def poll(self):
        return self.returncode
    def wait(self, timeout=None):
        self.waits += 1
        self.returncode = self.code
        return self.returncode


class ParentTests(unittest.TestCase):
    def setUp(self):
        # Any accidentally reached real process/network path fails the fixture.
        self.patches = [patch('subprocess.Popen', side_effect=AssertionError('real process forbidden')),
                        patch('subprocess.run', side_effect=AssertionError('real subprocess forbidden')),
                        patch.object(socket, 'socket', side_effect=AssertionError('network forbidden'))]
        for item in self.patches: item.start()
    def tearDown(self):
        for item in reversed(self.patches): item.stop()

    def test_power_closed_bounds(self):
        self.assertEqual(contract.power_policy(AC)['source'], 'AC Power')
        self.assertEqual(contract.power_policy(BATTERY)['batteryPercent'], 19)
        self.assertEqual(contract.power_policy(BATTERY.replace('19%', '15%'))['batteryPercent'], 15)
        for value in [BATTERY.replace('19%', '14%'), BATTERY.replace('19%', '101%'),
                      BATTERY.replace('19%', 'unknown%'), 'unknown', AC + AC, AC + 'x' * 65536]:
            with self.subTest(value=value[:60]), self.assertRaises(ValueError): contract.power_policy(value)

    def test_exact_free_pressure_zero_swap(self):
        value = sample(); value['actualFreeBytes'] = contract.MINIMUM_FREE
        contract.resource_policy(value, contract.PROFILES[PROFILE])
        for key, changed in [('actualFreeBytes', contract.MINIMUM_FREE - 1), ('actualFreeBytes', True),
                             ('pressureLevel', 3), ('pressureLevel', -1), ('pressureLevel', True),
                             ('reportedSwapBytes', '0.01'), ('reportedSwapBytes', '-1'), ('reportedSwapBytes', 0)]:
            with self.subTest(key=key, changed=changed), self.assertRaises((ValueError, ArithmeticError)):
                contract.resource_policy(dict(value, **{key: changed}), contract.PROFILES[PROFILE])

    def test_rss_and_owned_attribution(self):
        exe = Path('/fake/bundle/cluster-inference'); value = sample(123, exe)
        for profile in contract.PROFILES.values():
            value['nativeRSSBytes'] = profile['maximumSampledRSSBytes']
            contract.resource_policy(value, profile, 123, exe)
            with self.assertRaises(ValueError):
                contract.resource_policy(dict(value, nativeRSSBytes=value['nativeRSSBytes'] + 1), profile, 123, exe)
        for change in [dict(nativePID=124), dict(nativePGID=124), dict(nativeCommand='/other --mode x'),
                       dict(nativeRSSBytes=True), dict(nativeRSSBytes=-1)]:
            with self.subTest(change=change), self.assertRaises(ValueError):
                contract.resource_policy(dict(sample(123, exe), **change), contract.PROFILES[PROFILE], 123, exe)
        contract.resource_policy(sample(), contract.PROFILES[PROFILE])

    def test_exact_native_five_pairs(self):
        for profile in contract.PROFILES:
            for stage in (0, 1):
                cmd = contract.native_command('/exe', '/model', profile, stage)
                self.assertEqual(cmd, ['/exe', '--mode', 'qwen-dense-stage-load-check', '--model-dir', '/model',
                    '--registered-dense-profile', profile, '--stage-index', str(stage), '--timeout-seconds', '120'])
        for stage in (-1, 2, True, '0'):
            with self.assertRaises(ValueError): contract.native_command('/exe', '/model', PROFILE, stage)

    def test_result_binds_identity_and_scope(self):
        for profile in contract.PROFILES:
            for stage in (0, 1):
                parsed = contract.validate_result(raw(result(stage, profile)), profile, stage)
                self.assertTrue(parsed['outerIdentityAndScopeValidated'])
                self.assertFalse(parsed['independentTensorAuditPerformed'])
        for field, changed in [('stageIndex', True), ('schemaVersion', 1.0), ('selectedStageModelsLoaded', True),
                               ('fullCheckpointVerificationPasses', 2), ('forwardExecuted', True),
                               ('selectedParametersEvaluated', False), ('model', 'other')]:
            row = result(); row[field] = changed
            with self.subTest(field=field), self.assertRaises(ValueError): contract.validate_result(raw(row), PROFILE, 0)

    def test_result_rejects_nested_stale_plan_or_source(self):
        for scope, field, changed in [('load', 'stageIndex', 1), ('load', 'schemaVersion', True),
            ('load', 'verifiedAggregateSHA256', 'f' * 64), ('load', 'sourceConfigurationSHA256', 'f' * 64),
            ('load', 'bf16ConversionEnabled', 1), ('budget', 'stageIndex', True),
            ('budget', 'planFingerprint', 'c' * 64), ('budget', 'profileFingerprint', 'c' * 64),
            ('budget', 'resourceAdmissionPerformed', True)]:
            row = result(); row[scope][field] = changed
            with self.subTest(field=field), self.assertRaises(ValueError): contract.validate_result(raw(row), PROFILE, 0)

    def test_output_closed_line_and_json(self):
        value = raw(result())
        for changed in [value[:-1], value + b'\n', value + value,
                        value.replace(b'"schemaVersion":1', b'"schemaVersion":1,"schemaVersion":1', 1),
                        value.replace(b'"memory":[]', b'"memory":NaN'), b' ' * (contract.MAX_STDOUT + 1)]:
            with self.assertRaises(ValueError): contract.validate_result(changed, PROFILE, 0)
        row = result(); row['extra'] = False
        with self.assertRaises(ValueError): contract.validate_result(raw(row), PROFILE, 0)

    def test_bounded_regular_and_raw_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            p = Path(directory); data = b'{ "fabricated": true }\n'
            (p / 'config.json').write_bytes(data); (p / 'manifest.json').write_bytes(b'{}')
            profile = dict(configuration=hashlib.sha256(data).hexdigest(), manifest=hashlib.sha256(b'{}').hexdigest())
            self.assertEqual(contract.input_pins(p, profile)['config.json']['sizeBytes'], len(data))
            self.assertEqual((p / 'config.json').read_bytes(), data)
            with self.assertRaises(ValueError): contract.bounded_regular(p / 'config.json', 2)
            (p / 'link').symlink_to(p / 'config.json')
            with self.assertRaises(OSError): contract.bounded_regular(p / 'link', 100)
            (p / 'config.json').write_bytes(b'{"fabricated":true}')
            with self.assertRaises(ValueError): contract.input_pins(p, profile)

    def test_parent_argument_scope(self):
        base = ['--runtime', '/repo/experiments/cluster/runtime', '--release', '/release', '--model-dir', '/model',
                '--profile', PROFILE, '--stage-index', '0', '--expected-native-sha256', 'a' * 64, '--output', '/out']
        self.assertEqual(parent.parse_args(base).stage_index, 0)
        for suffix in [['--reuse-bundle', '/bundle'], ['--expected-bundle-manifest-sha256', 'b' * 64]]:
            with self.assertRaises(ValueError): parent.parse_args(base + suffix)
        for flag in ['--stage-cut', '--prompt-tokens', '--prefill-phase-trace-file']:
            with patch('sys.stderr'), self.assertRaises(SystemExit): parent.parse_args(base + [flag, '1'])

    def flow(self, stage=0, reuse=False, native_code=0, fail_sample=None, sample_change=None,
             source_post_failure=False, reuse_post_failure=False, cleanup_error=False, mutate_raw=False, stderr=b'',
             stream_pin_failure=False):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary).resolve(); repo = base / 'repo'; runtime = repo / 'experiments/cluster/runtime'
            runtime.mkdir(parents=True); release = base / 'release'; release.mkdir()
            (release / 'cluster-inference').write_bytes(b'FAKE BINARY - NEVER EXECUTED')
            model = base / 'model'; model.mkdir(); (model / 'config.json').write_bytes(b'{ "fake": 1 }\n')
            (model / 'manifest.json').write_bytes(b'{"fakeManifest":1}\n')
            profile = dict(contract.PROFILES[PROFILE], configuration=parent.sha(model / 'config.json'),
                           manifest=parent.sha(model / 'manifest.json'))
            out = base / 'result'; native_sha = parent.sha(release / 'cluster-inference')
            args = types.SimpleNamespace(runtime=runtime, release=release, model_dir=model, profile=PROFILE,
                stage_index=stage, expected_native_sha256=native_sha, output=out,
                reuse_bundle=base / 'external' if reuse else None,
                expected_bundle_manifest_sha256='c' * 64 if reuse else None)
            calls = dict(samples=0, verify=0, create=0, reference=0, cleanup=0, popen=0, snapshot=0)
            def observed(pid=None):
                calls['samples'] += 1; value = sample(pid, out / 'bundle/cluster-inference')
                if calls['samples'] == fail_sample: value.update(sample_change or {'actualFreeBytes': 0})
                return value
            def stop(process):
                calls['cleanup'] += 1
                if process.returncode is None: process.returncode = -15
                return ['invented cleanup failure'] if cleanup_error else []
            tiny = types.SimpleNamespace(sample=observed, read_command=lambda cmd: BATTERY if 'pmset' in cmd[0] else '',
                ENVIRONMENT={'DARKBLOOM_BF16_WEIGHTS':'1','DARKBLOOM_CBV2_ATTN_QUERY_BLOCK':'128','MLX_ENABLE_TF32':'1'},
                stop_owned=stop, owned_group=lambda pid: [])
            def write_json(path, value):
                path.write_text(json.dumps(value)); path.chmod(0o600)
            def archive_sources(runtime, output):
                (output / 'source/experiments/cluster/runtime').mkdir(parents=True)
                value = dict(files=[{'fake':True}]); write_json(output / 'source-manifest.json', value); return value
            def snapshot(source, dest):
                calls['snapshot'] += 1; dest.mkdir(); (dest / 'cluster-inference').write_bytes((source / 'cluster-inference').read_bytes())
                return 'c' * 64
            def verify(*a):
                calls['verify'] += 1
                if calls['verify'] > 1 and source_post_failure: raise ValueError('invented source postflight failure')
            modules = dict(bundle=types.SimpleNamespace(snapshot=snapshot), artifacts=object())
            archive = types.SimpleNamespace(write_json=write_json, archive_sources=archive_sources,
                load_archived_runtime=lambda *a: modules, verify_archive=verify)
            def create_reference(source, dest, manifest_pin, executable_pin, archived_runtime, artifacts):
                calls['create'] += 1
                self.assertEqual((manifest_pin, executable_pin), ('c' * 64, native_sha))
                self.assertEqual(archived_runtime, out / 'source/experiments/cluster/runtime')
                source.mkdir(); (source / 'cluster-inference').write_bytes((release / 'cluster-inference').read_bytes())
                dest.symlink_to(source, target_is_directory=True)
                return dict(manifestSHA256='c' * 64)
            def check_reference(*a):
                calls['reference'] += 1
                if calls['reference'] > 1 and reuse_post_failure: raise ValueError('invented reference postflight failure')
            reference = types.SimpleNamespace(create_reference=create_reference, check_reference=check_reference)
            def launch(command, **kwargs):
                calls['popen'] += 1
                self.assertTrue(kwargs['start_new_session']); self.assertEqual(kwargs['cwd'], out / 'bundle')
                self.assertEqual(kwargs['stdin'], parent.subprocess.DEVNULL)
                self.assertEqual(command, contract.native_command(out / 'bundle/cluster-inference', model, PROFILE, stage))
                self.assertEqual(kwargs['env']['DARKBLOOM_BF16_WEIGHTS'], '1')
                self.assertNotIn('DARKBLOOM_FAKE', kwargs['env'])
                kwargs['stdout'].write(raw(result(stage))); kwargs['stdout'].flush()
                kwargs['stderr'].write(stderr); kwargs['stderr'].flush()
                if mutate_raw: (model / 'config.json').write_bytes(b'changed after initial raw pin')
                return FakeProcess(native_code)
            bounded = parent.bounded_regular
            stream_reads = []
            def bounded_stream(path, limit):
                stream_reads.append(path)
                if stream_pin_failure and len(stream_reads) == 2:
                    raise ValueError('invented changed stream during postflight')
                return bounded(path, limit)
            with patch.dict(contract.PROFILES, {PROFILE: profile}), patch.object(parent, 'import_pinned',
                side_effect=lambda n: {'tiny_support.py':tiny,'prefill_compute_archive.py':archive,'owned_bundle_reference.py':reference}[n]), \
                patch.object(parent.subprocess, 'Popen', side_effect=launch), patch.dict(parent.os.environ, {'DARKBLOOM_FAKE':'x'}), \
                patch.object(parent, 'bounded_regular', side_effect=bounded_stream):
                receipt = parent.run(args)
            self.assertEqual((out / 'receipt.json').stat().st_mode & 0o777, 0o600)
            self.assertEqual(json.loads((out / 'receipt.json').read_text())['status'], receipt['status'])
            return receipt, calls

    def test_fake_stage0_and_stage1_success(self):
        for stage in (0, 1):
            receipt, calls = self.flow(stage=stage)
            self.assertEqual(receipt['status'], 'completed'); self.assertEqual(calls['popen'], 1)
            self.assertEqual(calls['cleanup'], 1); self.assertEqual(calls['snapshot'], 1)
            self.assertTrue(receipt['nativeReaped']); self.assertFalse(receipt['throughputQualification'])

    def test_fake_reuse_pre_and_postchecks_without_copy(self):
        receipt, calls = self.flow(reuse=True)
        self.assertEqual(receipt['status'], 'completed'); self.assertEqual(calls['reference'], 2)
        self.assertEqual(calls['snapshot'], 0); self.assertEqual(calls['create'], 1)

    def test_initial_refusal_creates_receipt_without_native(self):
        receipt, calls = self.flow(fail_sample=1)
        self.assertEqual(receipt['status'], 'failed'); self.assertEqual(calls['popen'], 0)
        self.assertIn('Actual free memory', receipt['primaryFailure']); self.assertEqual(calls['snapshot'], 0)

    def test_prelaunch_refusal_after_bundle_keeps_no_native(self):
        receipt, calls = self.flow(fail_sample=2)
        self.assertEqual(receipt['status'], 'failed'); self.assertEqual(calls['popen'], 0)
        self.assertEqual(calls['snapshot'], 1)

    def test_loading_resource_refusal_reaps_owned_process(self):
        for change in [dict(actualFreeBytes=contract.MINIMUM_FREE-1), dict(reportedSwapBytes='1'),
                       dict(nativeRSSBytes=4*contract.GIB+1)]:
            receipt, calls = self.flow(fail_sample=3, sample_change=change)
            self.assertEqual(receipt['status'], 'failed'); self.assertEqual(calls['popen'], 1)
            self.assertEqual(calls['cleanup'], 1); self.assertTrue(receipt['nativeReaped'])

    def test_native_failure_and_independent_cleanup_post_errors(self):
        receipt, calls = self.flow(reuse=True, native_code=1, source_post_failure=True,
                                   reuse_post_failure=True, cleanup_error=True)
        self.assertIn('Native selected-stage load failed', receipt['primaryFailure'])
        self.assertEqual(len(receipt['cleanupErrors']), 1)
        self.assertEqual({e['action'] for e in receipt['postRunErrors']},
                         {'source_archive_bundle_recheck','reused_bundle_reference_recheck'})
        self.assertEqual(calls['reference'], 2); self.assertEqual(receipt['status'], 'failed')

    def test_successful_native_with_later_source_drift_remains_failed(self):
        receipt, _ = self.flow(source_post_failure=True)
        self.assertIsNone(receipt['primaryFailure']); self.assertEqual(receipt['nativeExitCode'], 0)
        self.assertEqual(receipt['status'], 'failed'); self.assertEqual(len(receipt['postRunErrors']), 1)

    def test_raw_metadata_changed_after_start_is_retained_failure(self):
        receipt, _ = self.flow(mutate_raw=True)
        self.assertEqual(receipt['status'], 'failed')
        self.assertEqual(receipt['postRunErrors'][0]['action'], 'raw_metadata_recheck')

    def test_stderr_is_closed_empty_only(self):
        receipt, _ = self.flow(stderr=b'[bf16] invented diagnostic\n')
        self.assertEqual(receipt['status'], 'failed'); self.assertIn('emitted stderr', receipt['primaryFailure'])

    def test_stream_pin_failure_preserves_failed_receipt(self):
        receipt, _ = self.flow(stream_pin_failure=True)
        self.assertEqual(receipt['status'], 'failed'); self.assertIsNone(receipt['primaryFailure'])
        self.assertEqual(receipt['nativeExitCode'], 0)
        self.assertEqual(receipt['postRunErrors'][0]['action'], 'retained_stream_pin_stdout.jsonl')

    def test_observation_time_is_charged_before_success(self):
        with tempfile.TemporaryDirectory() as temporary:
            out = Path(temporary); (out/'stdout.jsonl').write_bytes(raw(result())); (out/'stderr.log').write_bytes(b'')
            process = FakeProcess(); receipt = dict(memorySamples=[],powerObservations=[],registeredProfile=PROFILE,stageIndex=0)
            tiny = types.SimpleNamespace(sample=lambda pid: sample(), read_command=lambda cmd: BATTERY)
            with self.assertRaisesRegex(ValueError, 'after observation'):
                parent.supervise(process,out,tiny,receipt,contract.PROFILES[PROFILE],lambda:None,clock=lambda:136,deadline=135)
            self.assertIsNone(process.returncode)

    def test_final_validation_time_is_charged(self):
        with tempfile.TemporaryDirectory() as temporary:
            out = Path(temporary); (out/'stdout.jsonl').write_bytes(raw(result())); (out/'stderr.log').write_bytes(b'')
            process = FakeProcess(); process.returncode = 0
            receipt = dict(memorySamples=[],powerObservations=[],registeredProfile=PROFILE,stageIndex=0)
            clock = iter([1,136])
            with self.assertRaisesRegex(ValueError, 'after output validation'):
                parent.supervise(process,out,None,receipt,contract.PROFILES[PROFILE],lambda:None,clock=lambda:next(clock),deadline=135)
            self.assertNotIn('outerIdentityAndScopeValidated', receipt)


if __name__ == '__main__':
    unittest.main()
