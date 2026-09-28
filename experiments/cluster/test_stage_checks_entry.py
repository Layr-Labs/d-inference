"""Public entry/snapshot checks without executing a worker or a system command."""

import contextlib
import io
from pathlib import Path
import runpy
import sys
import tempfile
import unittest
from unittest.mock import patch

from runtime.stage_checks import archive


class PublicEntryTests(unittest.TestCase):
    def setUp(self):
        for target in ('subprocess.Popen', 'subprocess.run', 'socket.socket'):
            guard = patch(target, side_effect=AssertionError('No process/socket calls'))
            guard.start()
            self.addCleanup(guard.stop)

    def test_public_help_adds_explicit_prefill_ranks(self):
        entry = Path(__file__).with_name('run_stage_checks.py')
        output = io.StringIO()
        with patch.object(sys, 'argv', [str(entry), '--help']), contextlib.redirect_stdout(output):
            with self.assertRaises(SystemExit) as stopped:
                runpy.run_path(str(entry), run_name='__main__')
        self.assertEqual(stopped.exception.code, 0)
        self.assertIn('{p2p,ranks,prefill-ranks,long-prefill-ranks,long-prefill-solo}', output.getvalue())
        self.assertNotIn('lookahead', output.getvalue())

    def test_snapshot_includes_exact_public_entry_and_runtime_module_sources(self):
        entry = Path(__file__).with_name('run_stage_checks.py')
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            records = archive.archive_launcher(output)
            names = {record['path'] for record in records}
            self.assertIn('run_stage_checks.py', names)
            self.assertIn('cli.py', names)
            self.assertIn('ranks.py', names)
            self.assertIn('prefill.py', names)
            self.assertIn('prefill_baseline.py', names)
            self.assertIn('prefill_resources.py', names)
            self.assertEqual((output / 'launcher/run_stage_checks.py').read_bytes(), entry.read_bytes())
            for record in records:
                self.assertEqual(archive.digest(output / 'launcher' / record['path']), record['sha256'])
                self.assertEqual(archive.digest(Path(record['source_path'])), record['sha256'])


if __name__ == '__main__':
    unittest.main()
