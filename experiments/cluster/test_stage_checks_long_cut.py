"""Explicit registered long cut admission; only synthetic inputs and fake IO."""
import argparse
import copy
from contextlib import redirect_stderr
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch
from runtime.stage_checks import cli, long_cli, long_configuration, long_inputs, long_rank_contract, long_solo_contract, long_stage_cut, stage_ranges
from runtime.stage_checks.common import canonical, digest
from runtime.stage_checks.long_identity import request_identity
from runtime.stage_checks.long_profile import ARTIFACT
from stage_long_test_support import EPOCH, context, rows
from stage_long_cut_test_support import CONFIGURATIONS, HOSTS, PLAN, STAGES, selected_context, selected_rows


class LongCutTests(unittest.TestCase):
    def setUp(self):
        for target in ('subprocess.Popen', 'subprocess.run', 'socket.socket'):
            guard = patch(target, side_effect=AssertionError('No real process/socket calls'))
            guard.start(); self.addCleanup(guard.stop)
        temporary = tempfile.TemporaryDirectory(); self.addCleanup(temporary.cleanup); self.root = Path(temporary.name)

    def arguments(self, mode='long-prefill-ranks'):
        args = [mode, '--release', '/unused-release', '--runtime', '/unused-runtime', '--output', '/unused-output',
            '--model-dir', '/unused-model', '--tokens-file', '/unused-tokens', '--prompt-origin-file', '/unused-origin',
            '--expected-binary-sha256', 'a' * 64, '--artifact-aggregate-sha256', ARTIFACT,
            '--tokens-sha256', 'b' * 64, '--prompt-origin-sha256', 'c' * 64]
        if mode.endswith('ranks'): args += ['--stage-prefill-policy', 'serial_v1', '--stage-logits-dtype', 'bfloat16']
        return args

    def test_parser_uses_existing_duplicate_guard_and_rejects_solo(self):
        self.assertEqual(cli.parser().parse_args(self.arguments() + ['--stage-cut', '12']).stage_cut, 12)
        self.assertIsNone(cli.parser().parse_args(self.arguments()).stage_cut)
        bad = [self.arguments() + ['--stage-cut', '12', '--stage-cut', '12'],
               self.arguments('long-prefill-solo') + ['--stage-cut', '12'], self.arguments() + ['--stage-cut', '12.0']]
        for args in bad:
            with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit): cli.parser().parse_args(args)

    def test_registered_geometry_reuses_shared_helper_and_keeps_eligibility_separate(self):
        with patch.object(stage_ranges, 'ranges', wraps=stage_ranges.ranges) as shared:
            self.assertEqual(long_stage_cut.for_context(selected_context()), 12)
        shared.assert_called_once_with(dict(num_hidden_layers=32, full_attention_interval=4), 12)
        for cut in (False, True, '12', 12.0, -1, 0, 4, 8, 16, 20, 24, 28, 32, 128):
            with self.subTest(cut=cut), self.assertRaises(ValueError):
                long_stage_cut.option('long-prefill-ranks', cut, 'serial_v1')
        with self.assertRaises(ValueError): long_stage_cut.option('long-prefill-ranks', 12, 'prompt_lookahead_one_v1')

    def test_foreign_and_unqualified_direct_calls_fail_before_io(self):
        for mode, policy in [('long-prefill-solo', None), ('ranks', 'serial_v1'), ('prefill-ranks', 'serial_v1'),
                             ('long-prefill-ranks', 'prompt_lookahead_one_v1')]:
            args = argparse.Namespace(command=mode, stage_cut=12, stage_prefill_policy=policy)
            with patch.object(Path, 'resolve', side_effect=AssertionError('No path IO')), patch.object(Path, 'open', side_effect=AssertionError('No input IO')):
                with self.assertRaises(ValueError): long_cli.run(args)
                with self.assertRaises(ValueError): long_inputs.prepare(args, self.root, EPOCH, Mock())
            ctx = dict(mode=mode, stage_cut=12, stage_prefill_policy=policy)
            with self.assertRaises(ValueError): long_configuration.build(0, ctx, '/bundle', 'c' * 64, HOSTS)
        with self.assertRaises(ValueError): long_solo_contract.validate({}, 0, dict(context('long-prefill-solo'), stage_cut=12))

    def test_selection_rejects_source_drift_and_context_mode_smuggling(self):
        for key, value in [('artifact', '0' * 64), ('configuration_sha256', '0' * 64), ('mode', 'long-prefill-solo')]:
            ctx = selected_context(); ctx[key] = value
            with self.assertRaises(ValueError): long_configuration.build(0, ctx, '/bundle', 'c' * 64, HOSTS)

    def test_default_argv_history_and_optional_phase_shape_are_preserved(self):
        for rank in (0, 1):
            for traced in (False, True):
                old = dict(context(), prefill_phase_trace=traced); selected = dict(old, stage_cut=12)
                base = long_configuration.build(rank, old, '/bundle', 'c' * 64, HOSTS)
                chosen = long_configuration.build(rank, selected, '/bundle', 'c' * 64, HOSTS)
                position = chosen['arguments'].index('--stage-cut')
                self.assertEqual(chosen['arguments'][position:position + 2], ['--stage-cut', '12'])
                self.assertEqual(chosen['arguments'].count('--stage-cut'), 1)
                del chosen['arguments'][position:position + 2]
                self.assertEqual(chosen, base)
                self.assertEqual(request_identity(EPOCH, old['prompt']), request_identity(EPOCH, selected['prompt']))
        self.assertEqual(long_stage_cut.agreement_fields(context()), {})
        self.assertEqual(long_stage_cut.source_fields(context()), {})

    def test_ready_binds_descriptor_before_accepting_rehashed_agreement(self):
        ctx = selected_context()
        for rank in (0, 1):
            ready, final = selected_rows(rank, ctx)
            long_rank_contract.validate(ready, 0, rank, EPOCH, 'serial_v1', ctx)
            long_rank_contract.validate(final, 1, rank, EPOCH, 'serial_v1', ctx, ready)
        for key in ('planFingerprint', 'producerStageFingerprint', 'consumerStageFingerprint',
                    'producerConstructionConfigurationSHA256', 'consumerConstructionConfigurationSHA256'):
            ready = selected_rows()[0]; ready['agreement'][key] = 'f' * 64
            ready['agreementFingerprint'] = digest(b'qwen-profiled-prefill-start-agreement-v1\n' + canonical(ready['agreement']))
            with self.subTest(key=key), self.assertRaises(ValueError):
                long_rank_contract.validate(ready, 0, 0, EPOCH, 'serial_v1', ctx)
        with self.assertRaises(ValueError): long_rank_contract.validate(rows()[0], 0, 0, EPOCH, 'serial_v1', ctx)

    def test_existing_source_loop_binds_local_stage_and_full_source_descriptor(self):
        ctx = selected_context()
        for rank in (0, 1):
            changes = [('stageIndex', 1 - rank), ('stagePlanSHA256', STAGES[1 - rank]),
                ('constructionConfigurationSHA256', CONFIGURATIONS[1 - rank]), ('sourceParameterLayoutSHA256', 'f' * 64),
                ('sourceModelTensorBytes', 5038041600.0), ('storageCommitmentSHA256', 'f' * 64)]
            for key, value in changes:
                ready, final = selected_rows(rank, ctx); final['sourceLoad'][key] = value
                with self.subTest(rank=rank, key=key), self.assertRaises(ValueError):
                    long_rank_contract.validate(final, 1, rank, EPOCH, 'serial_v1', ctx, ready)

    def test_receipt_records_selected_identity_without_adding_a_numerical_claim(self):
        value = long_stage_cut.receipt(selected_context())
        self.assertEqual(value['source_layer_ranges'], [[0, 12], [12, 32]])
        self.assertEqual(value['plan_sha256'], PLAN)
        self.assertTrue(value['source_identity_validation_only'])
        self.assertFalse(value['independent_numerical_action_timing_audit_performed'])
        value['source_layer_ranges'][0][1] = 16
        self.assertEqual(long_stage_cut.receipt(selected_context())['source_layer_ranges'], [[0, 12], [12, 32]])


if __name__ == '__main__': unittest.main()
