"""Reuse the public fake lifecycle harness for the selected long rank path."""
from pathlib import Path
import unittest
from unittest.mock import Mock, patch
from runtime.stage_checks import long_configuration, long_stage_cut, long_supervision
from runtime.stage_checks.common import digest, parse
import test_stage_checks_long_launch as inherited_launch
import test_stage_checks_long_flow as inherited_flow
from stage_long_cut_test_support import HOSTS, PLAN, selected_context, selected_rows


class LongCutFlowTests(unittest.TestCase):
    def launch(self, *, post_failure=False, wrong_plan=False):
        harness = inherited_launch.LongLaunchTests(methodName='runTest')
        harness.setUp(); self.addCleanup(harness.doCleanups)
        original_arguments = harness.arguments
        def arguments(mode, output): return original_arguments(mode, output) + ['--stage-cut', '12']
        def native_rows(rank, context):
            values = selected_rows(rank, context)
            if wrong_plan:
                # Both peers agree on a stale source; selection must still refuse.
                from runtime.stage_checks.common import canonical
                for value in values:
                    value['agreement']['planFingerprint'] = 'f' * 64
                    value['agreementFingerprint'] = digest(b'qwen-profiled-prefill-start-agreement-v1\n' + canonical(value['agreement']))
                values[1]['sourceLoad']['planSHA256'] = 'f' * 64
            return values
        # The inherited harness already substitutes a tiny synthetic config pin
        # in long_inputs; keep that same fake pin at the selected-context gate.
        # This tests plumbing and ownership, not registered model qualification.
        with patch.object(harness, 'arguments', side_effect=arguments), \
             patch.object(inherited_launch, 'rows', side_effect=native_rows), \
             patch.object(long_stage_cut, 'CONFIGURATION', digest(harness.config)):
            code, receipt, output = harness.execute(post_failure=post_failure)
        return harness, code, receipt, output

    def test_full_fake_entry_retains_cut_raw_inputs_and_opaque_audit_scope(self):
        harness, code, receipt, output = self.launch()
        self.assertEqual(code, 0); self.assertTrue(receipt['passed'])
        self.assertEqual(receipt['selected_layer_plan']['source_layer_ranges'], [[0, 12], [12, 32]])
        self.assertEqual(receipt['selected_layer_plan']['plan_sha256'], PLAN)
        self.assertFalse(receipt['independent_numerical_action_timing_audit']['performed'])
        self.assertFalse(receipt['throughput_qualification'])
        ctx = parse((output / 'context.json').read_bytes()); self.assertEqual(ctx['stage_cut'], 12)
        for rank in (0, 1):
            directory = output / ('rank-' + str(rank)); config = parse((directory / 'rank.json').read_bytes())
            index = config['arguments'].index('--stage-cut')
            self.assertEqual(config['arguments'][index:index + 2], ['--stage-cut', '12'])
            self.assertEqual(config['input_files'], {})
            self.assertEqual((directory / 'prompt.json').read_bytes(), harness.prompt.read_bytes())
        self.assertEqual(len(receipt['rank_files']), 10)
        self.assertEqual(harness.events[:3], ['initial', 'memory', 'source'])
        self.assertTrue(all(child.waits == 1 for child in harness.children))

    def test_full_fake_entry_rejects_coherently_wrong_plan_and_fences_both(self):
        harness, code, receipt, _ = self.launch(wrong_plan=True)
        self.assertEqual(code, 1); self.assertFalse(receipt['passed'])
        self.assertTrue(harness.stops); self.assertTrue(all(owners == [0, 1] for owners in harness.stops))
        self.assertEqual(len(harness.children), 2); self.assertTrue(all(child.waits == 1 for child in harness.children))

    def test_selected_post_run_source_failure_preserves_completed_cohort_and_cleanup(self):
        harness, code, receipt, _ = self.launch(post_failure=True)
        self.assertEqual(code, 1); self.assertTrue(receipt['cohort']['passed'])
        self.assertIn('post-run source drift', receipt['primary_failure']['error'])
        self.assertEqual(harness.stops, [[0, 1]])

    def test_selected_deadline_fences_all_fake_owners(self):
        harness = inherited_flow.LongFlowTests(methodName='runTest')
        harness.setUp(); self.addCleanup(harness.doCleanups)
        with patch.object(inherited_flow, 'context', side_effect=lambda _mode: selected_context()), \
             patch.object(inherited_flow, 'rows', side_effect=selected_rows):
            result = harness.execute(finish=10)
        self.assertFalse(result['passed']); self.assertEqual(result['cancellation_reason'], 'cohort_deadline')
        self.assertEqual(harness.stops, [[0, 1]]); self.assertTrue(all(child.waits == 1 for child in harness.children))

    def test_direct_staging_and_supervision_refuse_unqualified_context_before_io(self):
        ctx = dict(selected_context(), stage_prefill_policy='prompt_lookahead_one_v1')
        with patch.object(Path, 'open', side_effect=AssertionError('No input file read')):
            with self.assertRaises(ValueError): long_configuration.stage(Path('/unused'), ctx, 'b' * 64, HOSTS)
        start = Mock(side_effect=AssertionError('No process start'))
        with self.assertRaises(ValueError):
            long_supervision.run([], ctx, 1, start, Mock(), Mock(), clock=Mock(side_effect=AssertionError('No clock read')))
        start.assert_not_called()


if __name__ == '__main__': unittest.main()
