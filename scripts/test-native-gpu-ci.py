#!/usr/bin/env python3
"""CPU-only tests of native CI routing and tripwires; never invoke real Swift."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
MEMORY = 'evaluatedPagesAvoidDoubleTaxAndRetainedAliasKeepsPressure'
COMPOSITION = 'decodeBatchCompositionInvariance'
EXCLUSIVE = (MEMORY, COMPOSITION)
CPU_CHECKPOINT = ('SSDShorterNativeBlockRestoreTests', 'SSDNativeCheckpointOracleTests')
FAKE_SWIFT = r'''
import json, os, sys
args = sys.argv[1:]
selected = args[args.index('--filter') + 1] if '--filter' in args else 'general'
flag = os.environ.get('DARKBLOOM_EXCLUSIVE_NATIVE_GPU_TEST')
with open(os.environ['FAKE_SWIFT_LOG'], 'a') as log:
    log.write(json.dumps({'filter': selected, 'args': args, 'exclusive': flag,
                         'deadline_isolated': os.environ.get('DARKBLOOM_ISOLATED_DEADLINE_TEST'),
                         'mimo_native': os.environ.get('MIMO_V26_SERIAL_NATIVE_TESTS'),
                         'profile': os.environ.get('LLVM_PROFILE_FILE')}) + '\n')
xunit = args[args.index('--xunit-output') + 1] if '--xunit-output' in args else None
def report(*cases):
    # SwiftPM's Swift Testing report beside the requested path; XCTest
    # writes none without --parallel. A case is (name, skipped).
    if xunit is not None:
        base, extension = os.path.splitext(xunit)
        body = ''.join(f'<testcase classname="M.S" name="{name}"'
                       + ('><skipped /></testcase>' if skip else ' />') for name, skip in cases)
        with open(base + '-swift-testing' + extension, 'w') as stream:
            stream.write(f'<testsuites><testsuite name="TestResults" tests="{len(cases)}" '
                         f'skipped="{sum(skip for _, skip in cases)}">{body}</testsuite></testsuites>')
def interleaved(*parts):
    # SwiftPM's warning goes to stderr between two writes of one stdout line.
    for stream, text in parts:
        stream.buffer.write(text)
        stream.flush()
if selected == os.environ.get('FAKE_SWIFT_FAIL'):
    print('simulated assertion failure')
    raise SystemExit(17)
if selected == os.environ.get('FAKE_SWIFT_EMPTY'):
    print('Test run with 0 tests passed after 0.001 seconds.')
    report()
    raise SystemExit(0)
if selected == os.environ.get('FAKE_SWIFT_SPLIT'):
    warning = b"warning: '--build-system native' has been deprecated and will be removed in a future release\n"
    split = os.environ.get('FAKE_SWIFT_SPLIT_AT', 'line')
    if os.environ.get('FAKE_SWIFT_SPLIT_SKIP'):
        interleaved((sys.stdout, '➜ Test synthetic() skip'.encode()), (sys.stderr, warning),
                    (sys.stdout, b'ped: "missing fixture"\n'))
    if split == 'glyph':
        # Run 44903589432: the warning inside the leading glyph.
        interleaved((sys.stdout, b'\xe2'), (sys.stderr, warning),
                    (sys.stdout, b'\x9c\x94 Test run with 29 tests in 3 suites passed after 66.264 seconds.\n'))
    else:
        # Run 44909219943: the warning inside the count's line.
        interleaved((sys.stdout, '✔ Test run with 29'.encode()), (sys.stderr, warning),
                    (sys.stdout, b' tests in 3 suites passed after 72.041 seconds.\n'))
    report(*[(f'test{index}()', False) for index in range(29 - bool(os.environ.get('FAKE_SWIFT_SPLIT_SKIP')))],
           *([('synthetic()', True)] if os.environ.get('FAKE_SWIFT_SPLIT_SKIP') else []))
    raise SystemExit(0)
if selected == os.environ.get('FAKE_SWIFT_NO_XUNIT'):
    print('✔ Test run with 1 test passed after 0.001 seconds.')
    raise SystemExit(0)
if selected == os.environ.get('FAKE_SWIFT_BAD_XUNIT'):
    print('✔ Test run with 1 test passed after 0.001 seconds.')
    base, extension = os.path.splitext(xunit)
    with open(base + '-swift-testing' + extension, 'w') as stream:
        stream.write('<?xml version="1.0" encoding="UTF-8"?>\n<testsuites>\n')
    raise SystemExit(0)
if selected == os.environ.get('FAKE_SWIFT_CANCEL'):
    # Swift Testing's report lists a test that ended itself with Test.cancel as run.
    print('➜ Test sampler() was cancelled after 4.365 seconds: "the pageout scan did not run in 4 s"')
    print('✔ Test run with 1 test passed after 4.365 seconds.')
    report(('sampler()', False))
    raise SystemExit(0)
if selected == os.environ.get('FAKE_SWIFT_BOTH'):
    print("Test Suite 'Selected tests' passed at 2026-11-21 06:00:42.158.")
    print('\t Executed 2 tests, with 0 failures (0 unexpected) in 0.001 (0.001) seconds')
    print('✔ Test run with 3 tests in 1 suite passed after 0.001 seconds.')
    report(('a()', False), ('b()', False), ('c()', False))
    raise SystemExit(0)
exclusive = selected in ('evaluatedPagesAvoidDoubleTaxAndRetainedAliasKeepsPressure',
                         'decodeBatchCompositionInvariance')
skipped = selected == os.environ.get('FAKE_SWIFT_SKIP') or (exclusive and flag != '1')
if selected == 'ProcessMemoryNativeIntegrationTests':
    skipped = True
if selected == 'CBv2PagedKernelTests' and '--skip' not in args:
    skipped = True
if skipped:
    if os.environ.get('FAKE_SWIFT_SKIP_STYLE') == 'xctest':
        print('Executed 1 test, with 1 test skipped and 0 failures (0 unexpected)')
        report()
    else:
        print('➜ Test synthetic() skipped: "missing exclusive precondition"')
        report(('synthetic()', True))
    print('✔ Test run with 1 test passed after 0.001 seconds.')
    raise SystemExit(0)
if not exclusive and flag is not None:
    print('exclusive opt-in leaked to an ordinary invocation')
    raise SystemExit(19)
print('✔ Test run with 1 test passed after 0.001 seconds.')
report(('passed()', False))
'''


class NativeGPUTestRouting(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='native-ci-routing-')
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name)
        binary = self.work / 'bin'
        binary.mkdir()
        swift = binary / 'swift'
        swift.write_text('#!' + sys.executable + '\n' + FAKE_SWIFT)
        swift.chmod(0o700)
        self.log = self.work / 'calls.jsonl'
        keep = {'HOME', 'TMPDIR', 'LANG', 'LC_ALL', 'SYSTEMROOT'}
        self.env = {key: value for key, value in os.environ.items() if key in keep}
        self.env.update(PATH=str(binary) + ':/usr/bin:/bin',
                        FAKE_SWIFT_LOG=str(self.log),
                        DARKBLOOM_EXCLUSIVE_NATIVE_GPU_TEST='inherited-must-not-leak')

    def run_script(self, name, *args, **changes):
        if self.log.exists():
            self.log.unlink()
        result = subprocess.run(['bash', str(ROOT / 'scripts' / name), *args],
                                cwd=self.work, env={**self.env, **changes},
                                text=True, errors='replace', capture_output=True, timeout=20)
        calls = [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []
        return result, calls

    def test_provider_routes_every_isolated_case_without_flag_leakage(self):
        result, calls = self.run_script('run-provider-tests.sh')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual([row['filter'] for row in calls], [
            'general', *CPU_CHECKPOINT, 'emptyNativePoolTeardownUsesActualRetiredAdapter',
            'processLedgerCannotCombineOldUsageWithNewMaterializationCredit',
            'defaultApplyProjectsSettings', 'stageDelta', 'SpecDecHuggingFaceTests',
            'acceptedThenExpired', MEMORY])
        skip = calls[0]['args'][calls[0]['args'].index('--skip') + 1]
        self.assertIn('ProcessMemoryNativeIntegrationTests', skip)
        self.assertIn('SpecDecHuggingFaceTests', skip)
        for selected in CPU_CHECKPOINT:
            self.assertIn(selected, skip)
        for row in calls:
            self.assertIn('--no-parallel', row['args'])
            self.assertEqual(row['exclusive'], '1' if row['filter'] == MEMORY else None)
            self.assertEqual(row['deadline_isolated'], '1' if row['filter'] == 'acceptedThenExpired' else None)

    def test_general_provider_runner_does_not_enable_mimo_native_suites(self):
        result, calls = self.run_script('run-provider-tests.sh', MIMO_V26_SERIAL_NATIVE_TESTS='1')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(all(row['mimo_native'] is None for row in calls))

    def test_coverage_dir_gives_every_provider_test_process_a_profile_path(self):
        result, calls = self.run_script('run-provider-tests.sh')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual({row['profile'] for row in calls}, {None})
        profiles = self.work / 'profiles'
        result, calls = self.run_script('run-provider-tests.sh', PROVIDER_COVERAGE_DIR=str(profiles))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(calls), 10)
        self.assertEqual({row['profile'] for row in calls}, {f'{profiles}/%p-%m.profraw'})
        # swift test --enable-code-coverage would delete earlier profiles.
        self.assertTrue(all('--enable-code-coverage' not in row['args'] for row in calls))
        self.assertTrue(profiles.is_dir())

    def test_kernel_suite_and_composition_use_separate_invocations(self):
        result, calls = self.run_script('run-paged-kernel-tests.sh')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual([row['filter'] for row in calls], ['CBv2PagedKernelTests', COMPOSITION])
        self.assertEqual(calls[0]['args'][calls[0]['args'].index('--skip') + 1], COMPOSITION)
        self.assertIsNone(calls[0]['exclusive'])
        self.assertEqual(calls[1]['exclusive'], '1')
        self.assertTrue(all('--no-parallel' in row['args'] for row in calls))

    def test_general_failure_does_not_silence_provider_isolated_gates(self):
        result, calls = self.run_script('run-provider-tests.sh', FAKE_SWIFT_FAIL='general')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(calls), 10)
        self.assertEqual(calls[-1]['filter'], MEMORY)

    def test_cpu_checkpoint_gates_reject_failure_empty_and_skips_without_hiding_later_gates(self):
        for selected in CPU_CHECKPOINT:
            for changes in (
                {'FAKE_SWIFT_FAIL': selected},
                {'FAKE_SWIFT_EMPTY': selected},
                {'FAKE_SWIFT_SKIP': selected},
                {'FAKE_SWIFT_SKIP': selected, 'FAKE_SWIFT_SKIP_STYLE': 'xctest'},
            ):
                with self.subTest(selected=selected, changes=changes):
                    result, calls = self.run_script('run-provider-tests.sh', **changes)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(len(calls), 10)
                    self.assertEqual(calls[-1]['filter'], MEMORY)
                    self.assertEqual(sum(row['filter'] == selected for row in calls), 1)

    def test_huggingface_isolation_failure_does_not_silence_exclusive_gate(self):
        result, calls = self.run_script(
            'run-provider-tests.sh', FAKE_SWIFT_FAIL='SpecDecHuggingFaceTests')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual([row['filter'] for row in calls[-3:]],
                         ['SpecDecHuggingFaceTests', 'acceptedThenExpired', MEMORY])
        self.assertIsNone(calls[-3]['exclusive'])
        self.assertEqual(calls[-1]['exclusive'], '1')

    def test_ordinary_kernel_failure_does_not_silence_composition_gate(self):
        result, calls = self.run_script('run-paged-kernel-tests.sh', FAKE_SWIFT_FAIL='CBv2PagedKernelTests')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual([row['filter'] for row in calls], ['CBv2PagedKernelTests', COMPOSITION])

    def test_exclusive_assertion_failure_propagates_to_each_parent(self):
        for runner, selected in [('run-provider-tests.sh', MEMORY), ('run-paged-kernel-tests.sh', COMPOSITION)]:
            with self.subTest(runner=runner):
                result, calls = self.run_script(runner, FAKE_SWIFT_FAIL=selected)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(calls[-1]['filter'], selected)

    def test_actual_skip_is_rejected_even_when_aggregate_says_passed(self):
        for selected in EXCLUSIVE:
            for style in ('swift-testing', 'xctest'):
                with self.subTest(selected=selected, style=style):
                    result, _ = self.run_script('run-exclusive-native-gpu-test.sh', selected,
                                                FAKE_SWIFT_SKIP=selected, FAKE_SWIFT_SKIP_STYLE=style)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn('skipped one or more tests', result.stdout)

    def test_zero_executed_tests_is_rejected(self):
        for selected in EXCLUSIVE:
            with self.subTest(selected=selected):
                result, _ = self.run_script('run-exclusive-native-gpu-test.sh', selected,
                                            FAKE_SWIFT_EMPTY=selected)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('executed ZERO tests', result.stdout)

    def test_mimo_gate_rejects_empty_and_skipped_runs(self):
        self.env.pop('DARKBLOOM_EXCLUSIVE_NATIVE_GPU_TEST')
        selected = 'MiMoV26NativeLoadTransactionTests.testNativeCompletePrefix'
        result, calls = self.run_script('run-nested-suite.sh', selected, '--no-parallel',
                                        FAKE_SWIFT_EMPTY=selected)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('executed ZERO tests', result.stdout)
        self.assertEqual(len(calls), 1)
        for style in ('swift-testing', 'xctest'):
            with self.subTest(style=style):
                result, _ = self.run_script('run-nested-suite.sh', selected, '--no-parallel',
                                            FAKE_SWIFT_SKIP=selected, FAKE_SWIFT_SKIP_STYLE=style)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('skipped one or more tests', result.stdout)

    def test_nested_suite_counts_from_xunit_when_a_warning_splits_the_console(self):
        # SwiftPM's stderr warning landed inside the summary line: in the
        # count's line (run 44909219943) and in its glyph (run 44903589432).
        # The merged console then shows no count; the xUnit report still does.
        self.env.pop('DARKBLOOM_EXCLUSIVE_NATIVE_GPU_TEST')
        selected = 'PrefixDiskEncodingTests'
        for split_at in ('line', 'glyph'):
            with self.subTest(split_at=split_at):
                result, calls = self.run_script('run-nested-suite.sh', selected, '--no-parallel',
                                                FAKE_SWIFT_SPLIT=selected, FAKE_SWIFT_SPLIT_AT=split_at)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn('warning:', result.stderr)
                self.assertIn(f'{selected}: executed 29 Swift Testing tests (xunit-swift-testing.xml) '
                              'and 0 XCTest tests; 0 skipped', result.stdout)
                xunit = calls[0]['args'][calls[0]['args'].index('--xunit-output') + 1]
                self.assertTrue(xunit.endswith('/xunit.xml'), xunit)
                self.assertFalse(Path(xunit).parent.exists())

    def test_nested_suite_fails_a_skip_the_split_console_hides(self):
        self.env.pop('DARKBLOOM_EXCLUSIVE_NATIVE_GPU_TEST')
        selected = 'PrefixDiskEncodingTests'
        result, _ = self.run_script('run-nested-suite.sh', selected, '--no-parallel',
                                    FAKE_SWIFT_SPLIT=selected, FAKE_SWIFT_SPLIT_SKIP='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('skipped one or more tests', result.stdout)
        self.assertNotIn('executed ZERO tests', result.stdout)

    def test_nested_suite_fails_without_a_readable_report(self):
        self.env.pop('DARKBLOOM_EXCLUSIVE_NATIVE_GPU_TEST')
        selected = 'PrefixDiskEncodingTests'
        for change, message in (('FAKE_SWIFT_NO_XUNIT', 'wrote no Swift Testing xUnit report'),
                                ('FAKE_SWIFT_BAD_XUNIT', 'wrote an unreadable Swift Testing xUnit report')):
            with self.subTest(change=change):
                result, _ = self.run_script('run-nested-suite.sh', selected, '--no-parallel',
                                            **{change: selected})
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn(f'::error::{selected} {message}', result.stdout)

    def test_nested_suite_counts_a_self_cancelled_test_as_run(self):
        # StageLoadRealSamplerTests cancels when the host's pageout scan gives
        # it nothing to judge (run 44912466550); that is not a skip.
        self.env.pop('DARKBLOOM_EXCLUSIVE_NATIVE_GPU_TEST')
        selected = 'StageLoadRealSamplerTests'
        result, _ = self.run_script('run-nested-suite.sh', selected, '--no-parallel', FAKE_SWIFT_CANCEL=selected)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f'{selected}: executed 1 Swift Testing tests (xunit-swift-testing.xml) '
                      'and 0 XCTest tests; 0 skipped', result.stdout)

    def test_nested_suite_counts_both_libraries(self):
        self.env.pop('DARKBLOOM_EXCLUSIVE_NATIVE_GPU_TEST')
        selected = 'MixedTests'
        result, _ = self.run_script('run-nested-suite.sh', selected, FAKE_SWIFT_BOTH=selected)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f'{selected}: executed 3 Swift Testing tests (xunit-swift-testing.xml) '
                      'and 2 XCTest tests; 0 skipped', result.stdout)

    def test_nested_suite_rejects_flags_that_move_its_counts(self):
        for argument in ('--parallel', '--xunit-output', '--xunit-output=/tmp/report.xml'):
            with self.subTest(argument=argument):
                result, calls = self.run_script('run-nested-suite.sh', 'AnySuite', argument)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(calls, [])

    def test_prompt_parity_runs_through_the_nested_suite_gate(self):
        # A copy beside a stub fixture preparer, so nothing is downloaded.
        repo = self.work / 'repo'
        scripts = repo / 'scripts'
        scripts.mkdir(parents=True)
        (repo / 'provider-swift').mkdir()
        for name in ('verify-prompt-parity.sh', 'run-nested-suite.sh'):
            (scripts / name).write_bytes((ROOT / 'scripts' / name).read_bytes())
            (scripts / name).chmod(0o755)
        (scripts / 'prepare-prompt-fixtures.py').write_text('')
        selected = 'ProductionPromptParityTests'
        for changes, expected in (({'FAKE_SWIFT_SPLIT': selected}, 0),
                                  ({'FAKE_SWIFT_SPLIT': selected, 'FAKE_SWIFT_SPLIT_SKIP': '1'}, 1),
                                  ({'FAKE_SWIFT_EMPTY': selected}, 1)):
            with self.subTest(changes=changes):
                if self.log.exists():
                    self.log.unlink()
                result = subprocess.run(['bash', str(scripts / 'verify-prompt-parity.sh')], cwd=self.work,
                                        env={**self.env, 'PROMPT_PARITY_SKIP_BUILD': '1', **changes},
                                        text=True, errors='replace', capture_output=True, timeout=20)
                self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
                calls = [json.loads(line) for line in self.log.read_text().splitlines()]
                self.assertEqual([row['filter'] for row in calls], [selected])
                self.assertIn('--skip-build', calls[0]['args'])
                self.assertEqual(calls[0]['args'][calls[0]['args'].index('--configuration') + 1], 'debug')

    def test_nested_suite_keeps_its_report_and_stdout_for_the_shard_audit(self):
        # Prompt Parity's counts for the shard audit (provider-test-shards.py
        # counts) read the gate's report and stdout, never the merged console.
        self.env.pop('DARKBLOOM_EXCLUSIVE_NATIVE_GPU_TEST')
        selected = 'ProductionPromptParityTests'
        reports = self.work / 'reports'
        reports.mkdir()
        prefix = reports / 'parity-prompt'
        xunit, stdout = reports / 'parity-prompt-swift-testing.xml', reports / 'parity-prompt.log'
        result, _ = self.run_script('run-nested-suite.sh', selected, NESTED_SUITE_REPORT=str(prefix),
                                    FAKE_SWIFT_SPLIT=selected)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('warning:', result.stderr)
        self.assertIn('✔ Test run with 29 tests in 3 suites passed', stdout.read_text())
        self.assertNotIn('warning:', stdout.read_text())
        counts = subprocess.run([sys.executable, str(ROOT / 'scripts/provider-test-shards.py'), 'counts', 'parity',
                                 selected, str(xunit), str(stdout), str(reports / 'shard-parity-prompt.json')],
                                env=self.env, text=True, capture_output=True, timeout=20)
        self.assertEqual(counts.returncode, 0, counts.stdout + counts.stderr)
        self.assertEqual(json.loads((reports / 'shard-parity-prompt.json').read_text()),
                         {'shard': 'parity', 'pattern': selected, 'processes': 1, 'swift_testing': 29, 'xctest': 0})
        # A later run that writes no report fails, and leaves no earlier one to count.
        result, _ = self.run_script('run-nested-suite.sh', selected, NESTED_SUITE_REPORT=str(prefix),
                                    FAKE_SWIFT_NO_XUNIT=selected)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(f'::error::{selected} wrote no Swift Testing xUnit report', result.stdout)
        self.assertFalse(xunit.exists())

    def test_exclusive_helper_rejects_broad_or_extra_selectors_before_swift(self):
        for args in [(), ('CBv2PagedKernelTests',), (MEMORY, '--filter', 'anything')]:
            with self.subTest(args=args):
                result, calls = self.run_script('run-exclusive-native-gpu-test.sh', *args)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(calls, [])

    def test_workflow_keeps_checked_entrypoints(self):
        # The test jobs, then CI (master)'s Release Integrity, which runs this
        # file among its concurrent checks.
        workflow = ((ROOT / '.github/workflows/provider-tests.yml').read_text()
                    + (ROOT / '.github/workflows/ci-master.yml').read_text())
        self.assertIn('python3 ../scripts/run-provider-test-watchdog.py', workflow)
        self.assertIn('-- ../scripts/run-provider-tests.sh', workflow)
        self.assertIn('\n          python3 scripts/test-native-gpu-ci.py\n', workflow)


if __name__ == '__main__':
    unittest.main()
