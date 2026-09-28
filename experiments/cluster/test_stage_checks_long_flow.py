"""Injected-clock lifecycle tests; no subprocess, socket, or native activity."""
import tempfile
from pathlib import Path
import unittest
from unittest.mock import patch
from runtime.stage_checks.common import canonical, digest
from runtime.stage_checks.long_supervision import run
from stage_long_test_support import Clock, Child, context, rows, write_rows


class LongFlowTests(unittest.TestCase):
    def setUp(self):
        for target in ('subprocess.Popen','subprocess.run','socket.socket'):
            guard = patch(target, side_effect=AssertionError('No real processes/sockets')); guard.start(); self.addCleanup(guard.stop)
        temp = tempfile.TemporaryDirectory(); self.addCleanup(temp.cleanup); self.base = Path(temp.name)
        self.clock = Clock(); self.children = []; self.stops = []

    def execute(self, mode='long-prefill-ranks', finish=.1, codes=(0,0), mutate=None, memory=None,
                failed_start=None, cleanup_failure=False):
        ctx = context(mode); ranks = []
        for rank in range(2 if mode.endswith('ranks') else 1):
            directory = self.base / str(rank); directory.mkdir()
            ranks.append(dict(rank=rank, host=None, local=str(directory)))
        def start(rank):
            index = rank['rank']
            if index == failed_start: raise RuntimeError('primary start failure')
            values = rows(index, ctx)
            if mutate: values = mutate(index, values)
            write_rows(rank['local'], values, mode.endswith('ranks'))
            child = Child(index, self.clock, finish, codes[index]); self.children.append(child); return child
        def stop(owners, children):
            self.stops.append([rank['rank'] for rank in owners])
            for child in children: child.finish = self.clock(); child.code = child.poll() or -15
            if cleanup_failure: raise RuntimeError('separate cleanup failure')
        return run(ranks, ctx, 1, start, stop, memory or (lambda:None), clock=self.clock, sleep=self.clock.sleep)

    def test_pair_fast_exit_drains_reports_reaps_and_does_not_claim_oracle(self):
        result = self.execute(finish=0)
        self.assertTrue(result['passed']); self.assertTrue(result['supervisors_reaped']); self.assertEqual(self.stops, [])
        self.assertEqual(result['validation']['records_per_owner'], [2,2])
        self.assertFalse(result['validation']['numerical_action_wire_timing_audit_performed'])
        self.assertTrue(all(child.waits == 1 for child in self.children))

    def test_solo_uses_one_owner_with_no_peer_claim(self):
        result = self.execute(mode='long-prefill-solo')
        self.assertTrue(result['passed']); self.assertEqual(result['validation']['records_per_owner'], [2])
        self.assertFalse(result['validation']['peer_agreement_validated'])

    def test_coherent_peer_agreement_mismatch_fences_both(self):
        def change(index, values):
            if index:
                for value in values:
                    value['agreement']['planFingerprint'] = 'c' * 64
                    value['agreementFingerprint'] = digest(b'qwen-profiled-prefill-start-agreement-v1\n' + canonical(value['agreement']))
                    if 'sourceLoad' in value: value['sourceLoad']['planSHA256'] = 'c' * 64
            return values
        result = self.execute(finish=10, mutate=change)
        self.assertFalse(result['passed']); self.assertIn('Peers disagree', result['error']); self.assertEqual(self.stops, [[0,1]])

    def test_deadline_fences_every_owner(self):
        result = self.execute(finish=10)
        self.assertEqual(result['cancellation_reason'], 'cohort_deadline'); self.assertEqual(self.stops, [[0,1]])

    def test_second_start_failure_cancels_both_paths(self):
        result = self.execute(finish=10, failed_start=1)
        self.assertIn('primary start failure', result['error']); self.assertEqual(self.stops, [[0,1]])
        self.assertEqual(len(result['supervisor_pids']), 1); self.assertFalse(result['supervisors_reaped'])

    def test_primary_memory_failure_survives_cleanup_error(self):
        def fail(): raise RuntimeError('primary memory failure')
        result = self.execute(finish=10, memory=fail, cleanup_failure=True)
        self.assertIn('primary memory failure', result['error'])
        self.assertIn('separate cleanup failure', result['cleanup_errors'][0]['error']); self.assertFalse(result['passed'])

    def test_completed_handles_do_not_hide_late_memory_deadline(self):
        result = self.execute(finish=0, memory=lambda:self.clock.sleep(2))
        self.assertEqual(result['cancellation_reason'], 'cohort_deadline'); self.assertFalse(result['passed'])

    def test_peer_exit_and_missing_terminal_fail_closed(self):
        result = self.execute(finish=0, codes=(1,0))
        self.assertEqual(result['cancellation_reason'], 'rank_failed'); self.assertEqual(self.stops, [[0,1]])

    def test_truncated_terminal_fences_after_fast_native_exit(self):
        result = self.execute(finish=0, mutate=lambda _rank, values:values[:1])
        self.assertFalse(result['passed']); self.assertIn('EOF', result['error']); self.assertEqual(self.stops, [[0,1]])


if __name__ == '__main__': unittest.main()
