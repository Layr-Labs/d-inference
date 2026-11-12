"""Observed macOS receiver options and unknown-option refusal before the gate."""
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parent.parent / 'gemma4-artifact-transfer-rsync-options-ready-20260917'
sys.path.insert(0, str(SOURCE))
import rsync_exec


class ObservedOptions(unittest.TestCase):
    def test_exact_observed_receiver_options(self):
        with tempfile.TemporaryDirectory(dir='/private/tmp') as temporary:
            path = Path(temporary) / 'lease'
            path.write_bytes(b'')
            fd = os.open(path, os.O_RDONLY)
            arguments = ['--server', '--partial', '-r', '-t', '--relative', '--dirs', '.', str(rsync_exec.STAGE) + '/']
            with patch.object(rsync_exec, 'PREPARATION', rsync_exec.BASE), \
                 patch.object(rsync_exec, 'check_sources', return_value='pin'), \
                 patch.object(sys, 'argv', ['receiver'] + arguments), \
                 patch.object(rsync_exec, 'acquire', return_value=(fd, {})), \
                 patch.object(rsync_exec, 'observe', return_value={'prohibited': []}), \
                 patch.object(rsync_exec, 'disk', return_value={}), \
                 patch.object(rsync_exec, 'record'), \
                 patch.object(rsync_exec, 'run_receiver') as run:
                rsync_exec.main()
                run.assert_called_once_with(['/usr/bin/rsync'] + arguments)
            with self.assertRaises(OSError):
                os.fstat(fd)

    def test_unknown_option_at_correct_destination_is_refused(self):
        for option in ['--delete', '--sender', '--daemon', '--relative=/outside']:
            arguments = ['--server', '-r', '-t', option, '.', str(rsync_exec.STAGE)]
            with patch.object(rsync_exec, 'PREPARATION', rsync_exec.BASE), \
                 patch.object(rsync_exec, 'check_sources', return_value='pin'), \
                 patch.object(sys, 'argv', ['receiver'] + arguments), \
                 patch.object(rsync_exec, 'acquire') as gate:
                with self.assertRaises(ValueError):
                    rsync_exec.main()
                gate.assert_not_called()


if __name__ == '__main__':
    unittest.main()
