"""Bounded owner flag/receipt delta; fabricated entry handles, no native or SSH."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import socket
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from long_rank_artifacts import rank_file_receipts
from long_rank_configuration import configuration, require_configuration
from long_rank_test_support import EPOCH, INPUTS
import test_long_rank_launch as existing_launch


class OwnerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='rank-owner-cpu-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for obj, name in [(subprocess, 'Popen'), (subprocess, 'run'), (socket, 'socket')]:
            guard = patch.object(obj, name, side_effect=AssertionError('Real process/socket forbidden'))
            guard.start()
            self.addCleanup(guard.stop)

    def test_fixed_owner_delta_both_ranks_policies_and_unaudited_receipt(self):
        path = Path(__file__).parent.parent / 'remote-long-rank-phase-launcher-draft/long_rank_configuration.py'
        self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(),
                         '1e5d45c2192f866de691a1c958ac776ab83ec4f7796249839a454303aec9e3b3')
        spec = importlib.util.spec_from_file_location('frozen_rank_phase_configuration', path)
        upstream = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(upstream)
        for policy in ('serial_v1', 'prompt_lookahead_one_v1'):
            for rank in (0, 1):
                args = ('/bundle', 'b' * 64, '/model', INPUTS['prompt_file_sha256'], rank, EPOCH, policy)
                before, after = upstream.configuration(*args), configuration(*args)
                expected = copy.deepcopy(before)
                expected['arguments'] += ['--prefill-owner-trace-file', '@rank/owner-trace.json']
                cut_index = expected['arguments'].index('--execution-path') + 2
                expected['arguments'][cut_index:cut_index] = ['--stage-cut', '12']
                self.assertEqual(after, expected)
                self.assertEqual(after['arguments'].count('--prefill-owner-trace-file'), 1)
                self.assertEqual(after['arguments'].count('--prefill-phase-trace-file'), 1)
                require_configuration(after, *args)
                with self.assertRaises(ValueError):
                    require_configuration(before, *args)
                for mutate in (lambda v: v['arguments'].__setitem__(-1, '@rank/phase-trace.json'),
                               lambda v: v['arguments'].extend(['--prefill-owner-trace-file', '@rank/owner-trace.json'])):
                    wrong = copy.deepcopy(after)
                    mutate(wrong)
                    with self.assertRaises(ValueError):
                        require_configuration(wrong, *args)
        status, receipt, calls, output = existing_launch.Tests.run_fake(self, True)
        self.assertEqual(status, 0)
        self.assertEqual(receipt['kind'], 'remote_qwen_long_prefill_rank_cut_owner_launcher')
        self.assertIs(receipt['phase_timing_requested'], True)
        self.assertIs(receipt['owner_timing_requested'], True)
        self.assertFalse(receipt['throughput_qualification'])
        self.assertFalse(receipt['independent_execution_oracle_run'])
        self.assertEqual([item for item in calls if item[0] == 'start'], [('start', 0), ('start', 1)])
        self.assertEqual(receipt['cohort']['local_ssh_clients_reaped'], [True, True])
        for rank in (0, 1):
            directory = output / ('rank-' + str(rank))
            value = json.loads((directory / 'rank.json').read_bytes())
            self.assertEqual(value['arguments'][-4:], [
                '--prefill-phase-trace-file', '@rank/phase-trace.json',
                '--prefill-owner-trace-file', '@rank/owner-trace.json'])
            for name in ('phase-trace.json', 'owner-trace.json'):
                (directory / name).write_bytes(b'fabricated, deliberately unvalidated sidecar')
        archived = rank_file_receipts(output)
        self.assertEqual(len(archived), 10)
        self.assertFalse(any('-trace' in item['path'] for item in archived))
        self.assertEqual(receipt['retrieved_remote_metadata'], [])


if __name__ == '__main__':
    unittest.main()
