"""Opt-in phase forwarding through the fake local entry; never executes a model."""
import copy
from contextlib import redirect_stderr
import io
from pathlib import Path
from types import SimpleNamespace
import unittest

from runtime.stage_checks import cli, long_artifacts, long_configuration, long_phase
from runtime.stage_checks.common import parse
from stage_long_test_support import context
import test_stage_checks_long_launch as existing_launch


class LongPhaseTests(unittest.TestCase):
    def setUp(self):
        existing_launch.LongLaunchTests.setUp(self)
        self.phase_enabled = True

    def arguments(self, mode, output):
        values = existing_launch.LongLaunchTests.arguments(self, mode, output)
        return values + (['--prefill-phase-trace'] if self.phase_enabled else [])

    def execute(self, **options):
        return existing_launch.LongLaunchTests.execute(self, **options)

    def test_parser_opt_in_and_default_for_both_long_commands(self):
        for mode in ('long-prefill-solo', 'long-prefill-ranks'):
            self.phase_enabled = False
            values = self.arguments(mode, self.base / 'output')
            self.assertIs(cli.parser().parse_args(values).prefill_phase_trace, False)
            self.assertIs(cli.parser().parse_args(values + ['--prefill-phase-trace']).prefill_phase_trace, True)

    def test_configuration_adds_only_fixed_owned_native_argument(self):
        for mode in ('long-prefill-solo', 'long-prefill-ranks'):
            ctx = context(mode)
            hosts = [['127.0.0.1:31001'], ['127.0.0.1:31002']] if mode.endswith('ranks') else None
            for rank in range(2 if hosts else 1):
                base = long_configuration.build(rank, ctx, Path('/bundle'), 'b' * 64, hosts)
                off = long_configuration.build(rank, dict(ctx, prefill_phase_trace=False), Path('/bundle'), 'b' * 64, hosts)
                traced = long_configuration.build(rank, dict(ctx, prefill_phase_trace=True), Path('/bundle'), 'b' * 64, hosts)
                expected = copy.deepcopy(base)
                expected['arguments'] += ['--prefill-phase-trace-file', '@rank/phase-trace.json']
                self.assertEqual(off, base)
                self.assertEqual(traced, expected)
                self.assertEqual(traced['arguments'].count('--prefill-phase-trace-file'), 1)

    def test_nonboolean_context_or_programmatic_option_rejected(self):
        for value in (None, 0, 1, 'true', '/unowned/trace.json'):
            with self.assertRaises(ValueError): long_phase.requested(SimpleNamespace(prefill_phase_trace=value))
            with self.assertRaises(ValueError): long_phase.arguments(dict(context(), prefill_phase_trace=value))
        self.assertFalse(long_phase.requested(SimpleNamespace()))

    def test_legacy_commands_and_arbitrary_trace_path_option_rejected(self):
        common = ['--release', str(self.release), '--runtime', str(self.runtime), '--output', str(self.base / 'output'),
                  '--expected-binary-sha256', 'b' * 64]
        model = ['--model-dir', str(self.model), '--artifact-aggregate-sha256', 'a' * 64,
                 '--tokens-file', str(self.prompt)]
        for mode in ('p2p', 'ranks', 'prefill-ranks'):
            values = [mode] + common + ([] if mode == 'p2p' else model)
            if mode == 'prefill-ranks':
                values += ['--stage-prefill-policy', 'serial_v1', '--stage-logits-dtype', 'bfloat16',
                           '--baseline-evidence-sha256', 'c' * 64, '--baseline-jsonl', '/unused/baseline',
                           '--baseline-sha256', 'd' * 64]
            captured = io.StringIO()
            with redirect_stderr(captured), self.assertRaises(SystemExit):
                cli.parser().parse_args(values + ['--prefill-phase-trace'])
            self.assertIn('unrecognized arguments: --prefill-phase-trace', captured.getvalue())
        for mode in ('long-prefill-solo', 'long-prefill-ranks'):
            with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                cli.parser().parse_args(self.arguments(mode, self.base / 'output') +
                                        ['--prefill-phase-trace-file', '/arbitrary/path'])

    def check_enabled_result(self, record, output, count):
        self.assertTrue(record['passed'])
        self.assertTrue(parse((output / 'context.json').read_bytes())['prefill_phase_trace'])
        request = record['phase_trace_request']
        self.assertEqual(request['expected_owned_relative_paths'],
                         ['rank-' + str(rank) + '/phase-trace.json' for rank in range(count)])
        self.assertIs(request['requested'], True)
        for field in ('included_in_rank_files', 'sidecars_verified', 'phase_semantics_audited'):
            self.assertIs(request[field], False)
        self.assertEqual(record['cohort']['validation']['records_per_owner'], [2] * count)
        for rank in range(count):
            directory = output / ('rank-' + str(rank))
            config = parse((directory / 'rank.json').read_bytes())
            self.assertEqual(config['arguments'][-2:], ['--prefill-phase-trace-file', '@rank/phase-trace.json'])
            self.assertFalse((directory / 'phase-trace.json').exists())
            (directory / 'phase-trace.json').write_bytes(b'fabricated unvalidated bytes')
        self.assertEqual(long_artifacts.rank_files(output, count == 2), record['rank_files'])
        self.assertEqual(len(record['rank_files']), 10 if count == 2 else 4)

    def test_pair_fake_entry_keeps_two_records_and_excludes_sidecars(self):
        code, record, output = self.execute()
        self.assertEqual(code, 0)
        self.check_enabled_result(record, output, 2)
        self.assertEqual(self.events.count('start'), 2)
        self.assertTrue(record['cohort']['supervisors_reaped'])

    def test_solo_fake_entry_keeps_one_owner_and_excludes_sidecars(self):
        code, record, output = self.execute(mode='long-prefill-solo')
        self.assertEqual(code, 0)
        self.check_enabled_result(record, output, 1)
        self.assertNotIn('ports', self.events)

    def test_default_entry_retains_old_context_and_receipt_shape(self):
        self.phase_enabled = False
        code, record, output = self.execute()
        self.assertEqual(code, 0)
        self.assertNotIn('phase_trace_request', record)
        self.assertNotIn('prefill_phase_trace', parse((output / 'context.json').read_bytes()))
        for rank in (0, 1):
            self.assertNotIn('--prefill-phase-trace-file', parse((output / ('rank-' + str(rank)) / 'rank.json').read_bytes())['arguments'])

    def test_opt_in_initial_refusal_never_starts_owners(self):
        code, record, output = self.execute(refuse=True)
        self.assertEqual(code, 1)
        self.assertEqual(self.events, ['initial'])
        self.assertFalse(record['native_execution_attempted'])
        self.assertTrue(record['phase_trace_request']['requested'])
        self.assertFalse(record['phase_trace_request']['sidecars_verified'])
        self.assertFalse((output / 'rank-0').exists())

    def test_opt_in_postrun_failure_still_fences_and_does_not_qualify_trace(self):
        code, record, _ = self.execute(post_failure=True)
        self.assertEqual(code, 1)
        self.assertFalse(record['passed'])
        self.assertTrue(record['cohort']['passed'])
        self.assertEqual(self.stops, [[0, 1]])
        self.assertFalse(record['phase_trace_request']['sidecars_verified'])


if __name__ == '__main__': unittest.main()
