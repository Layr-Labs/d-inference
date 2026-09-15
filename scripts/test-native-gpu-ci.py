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
FAKE_SWIFT = r'''
import json, os, sys
args = sys.argv[1:]
selected = args[args.index('--filter') + 1] if '--filter' in args else 'general'
flag = os.environ.get('DARKBLOOM_EXCLUSIVE_NATIVE_GPU_TEST')
with open(os.environ['FAKE_SWIFT_LOG'], 'a') as log:
    log.write(json.dumps({'filter': selected, 'args': args, 'exclusive': flag}) + '\n')
if selected == os.environ.get('FAKE_SWIFT_FAIL'):
    print('simulated assertion failure')
    raise SystemExit(17)
if selected == os.environ.get('FAKE_SWIFT_EMPTY'):
    print('Test run with 0 tests passed after 0.001 seconds.')
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
    else:
        print('➜ Test synthetic() skipped: "missing exclusive precondition"')
    print('✔ Test run with 1 test passed after 0.001 seconds.')
    raise SystemExit(0)
if not exclusive and flag is not None:
    print('exclusive opt-in leaked to an ordinary invocation')
    raise SystemExit(19)
print('✔ Test run with 1 test passed after 0.001 seconds.')
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
                                text=True, capture_output=True, timeout=20)
        calls = [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []
        return result, calls

    def test_provider_routes_every_isolated_case_without_flag_leakage(self):
        result, calls = self.run_script('run-provider-tests.sh')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual([row['filter'] for row in calls], [
            'general', 'emptyNativePoolTeardownUsesActualRetiredAdapter',
            'processLedgerCannotCombineOldUsageWithNewMaterializationCredit',
            'defaultApplyProjectsSettings', 'stageDelta', MEMORY])
        skip = calls[0]['args'][calls[0]['args'].index('--skip') + 1]
        self.assertIn('ProcessMemoryNativeIntegrationTests', skip)
        for row in calls:
            self.assertIn('--no-parallel', row['args'])
            self.assertEqual(row['exclusive'], '1' if row['filter'] == MEMORY else None)

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
        self.assertEqual(len(calls), 6)
        self.assertEqual(calls[-1]['filter'], MEMORY)

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

    def test_exclusive_helper_rejects_broad_or_extra_selectors_before_swift(self):
        for args in [(), ('CBv2PagedKernelTests',), (MEMORY, '--filter', 'anything')]:
            with self.subTest(args=args):
                result, calls = self.run_script('run-exclusive-native-gpu-test.sh', *args)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(calls, [])

    def test_workflow_keeps_checked_entrypoints(self):
        workflow = (ROOT / '.github/workflows/ci.yml').read_text()
        self.assertIn('run: ../scripts/run-provider-tests.sh', workflow)
        self.assertIn('run: ../../scripts/run-paged-kernel-tests.sh', workflow)
        self.assertIn('run: python3 scripts/test-native-gpu-ci.py', workflow)


if __name__ == '__main__':
    unittest.main()
