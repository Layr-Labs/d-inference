"""One explicit owner-trace delta check using generated inputs and fake controls."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import unittest
from unittest.mock import patch
from long_reference_configuration import configuration, require_rank_configuration
from long_reference_test_fixture import PROMPT_SHA
import test_long_solo_flow as flow


class OwnerTests(unittest.TestCase):
    def setUp(self):
        for name in ('subprocess.run', 'subprocess.Popen', 'socket.socket'):
            guard = patch(name, side_effect=AssertionError('Real process/socket forbidden'))
            guard.start(); self.addCleanup(guard.stop)

    def test_owner_flag_adds_only_exact_path_and_keeps_collection_separate(self):
        path = Path(__file__).parent.parent / 'remote-long-solo-phase-launcher-draft/long_reference_configuration.py'
        self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(),
                         'ab04553dfc4a0e35c2b5435f009ce2f270b01d3f25de6d98eca1d217240c0842')
        spec = importlib.util.spec_from_file_location('frozen_solo_phase_configuration', path)
        upstream = importlib.util.module_from_spec(spec); spec.loader.exec_module(upstream)
        args = ('/bundle', 'b' * 64, '/model', PROMPT_SHA)
        before, value = upstream.configuration(*args), configuration(*args)
        expected = copy.deepcopy(before)
        expected['arguments'] += ['--prefill-owner-trace-file', '@rank/owner-trace.json']
        self.assertEqual(value, expected)
        self.assertEqual(value['arguments'].count('--prefill-owner-trace-file'), 1)
        self.assertEqual(value['arguments'].count('--prefill-phase-trace-file'), 1)
        for arguments in [value['arguments'][:-2], value['arguments'][:-1] + ['@rank/other.json'],
                          value['arguments'] + ['--prefill-owner-trace-file', '@rank/owner-trace.json']]:
            wrong = copy.deepcopy(value); wrong['arguments'] = arguments
            with self.assertRaises(ValueError): require_rank_configuration(wrong, *args)
        fixture = flow.Tests(methodName='runTest'); fixture.setUp(); self.addCleanup(fixture.doCleanups)
        status, receipt, operations, uploads, starts, stops = fixture.run_fake()
        self.assertEqual(status, 0); self.assertTrue(receipt['passed'])
        self.assertEqual(receipt['kind'], 'remote_qwen_long_prefill_solo_owner_launcher')
        self.assertIs(receipt['owner_timing_requested'], True)
        self.assertIs(receipt['phase_timing_requested'], True)
        self.assertIs(receipt['timing_diagnostic_only'], True)
        self.assertEqual(operations, ['initial', 'before', 'observe', 'after'])
        self.assertEqual(len(starts), 1); self.assertFalse(stops)
        self.assertEqual(receipt['execution']['validated_outer_records'], 2)
        config = json.loads((fixture.path / 'output/native/rank.json').read_bytes())
        self.assertEqual(config['arguments'][-4:], ['--prefill-phase-trace-file', '@rank/phase-trace.json',
                                                   '--prefill-owner-trace-file', '@rank/owner-trace.json'])
        for name in ('phase-trace', 'owner-trace'):
            self.assertFalse(any(name in target for _, target in uploads))
            self.assertFalse(any(name in row['path'] for row in receipt['native_files']))
        self.assertNotIn('owner_trace_verified', receipt)
        self.assertEqual(receipt['retrieved_remote_metadata'], [])


if __name__ == '__main__': unittest.main()
