"""Fake clocks, processes and streams only; never runs a native/backend operation."""
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from readiness_stream import Streams, WARNING, MISMATCH
from readiness_supervision import supervise
from test_readiness import FakeProcess, EPOCH


class StrictMismatchTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for name in ('subprocess.run', 'subprocess.Popen', 'socket.socket'):
            guard = patch(name, side_effect=AssertionError('real process/socket forbidden'))
            guard.start(); self.addCleanup(guard.stop)

    def run_mismatch(self, first=0, never_second=False, bad_code=None, extra=b'', final_slow=False):
        now = [0.0]; children = []; stopped = []; ranks = []
        for rank in range(2):
            directory = self.root / str(rank); directory.mkdir()
            (directory/'stdout.jsonl').write_bytes(b'')
            (directory/'stderr.log').write_bytes(WARNING + MISMATCH + (extra if rank == first else b''))
            ranks.append(dict(rank=rank, host=None, local=str(directory)))
        def start(rank):
            child = FakeProcess(100 + rank['rank'], bad_code if bad_code is not None and rank['rank'] == first
                                else 1 if rank['rank'] == first else None)
            children.append(child); return child
        def stop(_ranks, values):
            stopped.append(True)
            for child in values:
                if child.code is None: child.code = 143
        def sleep(seconds):
            now[0] += seconds
            if not never_second and len(children) == 2:
                children[1-first].code = 1
        negative = Streams.negative; validations = [0]
        def validate(stream, *args, **kwargs):
            negative(stream, *args, **kwargs); validations[0] += 1
            if final_slow and validations[0] == 4: now[0] = 46.0
        with patch.object(Streams, 'negative', validate):
            result = supervise(ranks, EPOCH, 'warmup-mismatch', start, stop,
                               clock=lambda: now[0], sleep=sleep)
        return result, children, stopped

    def test_rank0_finishes_first_peer_can_finish_naturally(self):
        result, children, stopped = self.run_mismatch(first=0)
        self.assertTrue(result['scenario_passed']); self.assertFalse(result['native_success'])
        self.assertEqual(result['supervisor_exit_codes'], [1,1]); self.assertFalse(stopped)
        self.assertEqual([x.waits for x in children], [1,1])

    def test_rank1_finishes_first_peer_can_finish_naturally(self):
        result, children, stopped = self.run_mismatch(first=1)
        self.assertTrue(result['scenario_passed']); self.assertFalse(stopped)
        self.assertIsNone(result['supervisor_exit_codes_before_cancellation'])
        self.assertEqual([x.waits for x in children], [1,1])

    def test_single_semantic_exit_with_parent_retired_peer_is_not_pass(self):
        result, _, stopped = self.run_mismatch(first=1, never_second=True)
        self.assertFalse(result['scenario_passed']); self.assertTrue(stopped)
        self.assertEqual(result['supervisor_exit_codes'], [143,1])
        self.assertEqual(result['primary_reason'], 'parent_deadline')

    def test_exact_diagnostic_with_different_exit_is_not_pass(self):
        result, _, _ = self.run_mismatch(bad_code=2)
        self.assertFalse(result['scenario_passed'])
        self.assertEqual(result['primary_reason'], 'unexpected_rank_failure')

    def test_peer_loss_line_stays_outside_allowlist(self):
        result, _, _ = self.run_mismatch(extra=b'[ring] Socket 5 was closed by the peer\n')
        self.assertFalse(result['scenario_passed'])
        self.assertEqual(result['primary_reason'], 'output_memory_or_startup_failure')

    def test_final_mismatch_validation_is_inside_deadline(self):
        result, _, _ = self.run_mismatch(final_slow=True)
        self.assertFalse(result['scenario_passed']); self.assertFalse(result['native_success'])
        self.assertIn('final mismatch validation', result['cleanup_errors'][0]['error'])

    def test_each_role_requires_complete_exact_disagreement(self):
        for rank in (0,1):
            for suffix in (b'', MISMATCH[:-1], MISMATCH + b'extra\n'):
                with self.subTest(rank=rank, suffix=suffix):
                    directory = self.root / ('stream-'+str(rank)); directory.mkdir(exist_ok=True)
                    (directory/'stdout.jsonl').write_bytes(b'')
                    (directory/'stderr.log').write_bytes(WARNING + suffix)
                    stream = Streams(directory, rank, EPOCH, 'warmup-mismatch', lambda *_: None)
                    with self.assertRaises(ValueError): stream.negative(mismatch=True)


if __name__ == '__main__': unittest.main()
