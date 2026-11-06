"""Only the additive phase request: fake controls, no sidecar or native execution."""
import copy
import json
from pathlib import Path
import unittest
from unittest.mock import patch
from long_reference_configuration import configuration, require_rank_configuration
from long_reference_test_fixture import PROMPT_SHA
import test_long_solo_flow as flow


class PhaseTests(unittest.TestCase):
    def setUp(self):
        for name in ('subprocess.run', 'subprocess.Popen', 'socket.socket'):
            guard = patch(name, side_effect=AssertionError('Real process/socket forbidden'))
            guard.start(); self.addCleanup(guard.stop)

    def test_exact_phase_path_is_bound_to_rank_configuration(self):
        value = configuration('/bundle', 'b' * 64, '/model', PROMPT_SHA)
        self.assertEqual(value['arguments'][-4:-2], ['--prefill-phase-trace-file', '@rank/phase-trace.json'])
        self.assertEqual(value['arguments'].count('--prefill-phase-trace-file'), 1)
        self.assertEqual(value['arguments'][1], 'qwen-long-prefill-solo-check')
        for arguments in [value['arguments'][:-4] + value['arguments'][-2:],
                          value['arguments'][:-3] + ['@rank/other.json'] + value['arguments'][-2:],
                          value['arguments'] + ['--prefill-phase-trace-file', '@rank/phase-trace.json']]:
            wrong = copy.deepcopy(value); wrong['arguments'] = arguments
            with self.assertRaises(ValueError):
                require_rank_configuration(wrong, '/bundle', 'b' * 64, '/model', PROMPT_SHA)

    def test_complete_fake_run_requests_phase_without_sidecar_retrieval_claim(self):
        fixture = flow.Tests(methodName='runTest')
        fixture.setUp(); self.addCleanup(fixture.doCleanups)
        status, receipt, _, uploads, starts, stops = fixture.run_fake()
        self.assertEqual(status, 0); self.assertTrue(receipt['passed'])
        self.assertEqual(receipt['kind'], 'remote_qwen_long_prefill_solo_owner_launcher')
        self.assertIs(receipt['phase_timing_requested'], True)
        self.assertEqual(receipt['execution']['validated_outer_records'], 2)
        self.assertEqual(len(starts), 1); self.assertFalse(stops)
        config = json.loads((fixture.path / 'output/native/rank.json').read_text())
        self.assertEqual(config['arguments'][-4:-2], ['--prefill-phase-trace-file', '@rank/phase-trace.json'])
        self.assertFalse(any('phase-trace' in target for _, target in uploads))
        self.assertFalse(any('phase-trace' in value['path'] for value in receipt['native_files']))
        self.assertFalse((fixture.path / 'output/native/phase-trace.json').exists())
        self.assertNotIn('phase_trace_verified', receipt)


if __name__ == '__main__': unittest.main()
