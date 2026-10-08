"""Explicit reference pins and the unchanged 8K reference gate; fabricated only."""
import contextlib
import io
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch
import prepare_packet as helper
import test_handoff as fixtures


class ReferenceInputChecks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        fixtures.HandoffChecks.setUpClass()

    def setUp(self):
        self.files = fixtures.HandoffChecks()
        self.files.setUp()

    def tearDown(self):
        self.files.tearDown()

    def test_reference_arguments_required(self):
        for missing in ('--reference', '--reference-sha256'):
            argv = ['prepare_packet.py', '--output', str(self.files.root / 'packet'),
                    '--reference', str(self.files.paths[0]), '--reference-sha256', self.files.pins[0]]
            i = argv.index(missing); del argv[i:i+2]
            with patch.object(sys, 'argv', argv), contextlib.redirect_stderr(io.StringIO()), \
                 self.assertRaises(SystemExit) as caught:
                helper.main()
            self.assertEqual(caught.exception.code, 2)

    def test_explicit_reference_is_bound_by_cli(self):
        output = self.files.root / 'packet'
        argv = ['prepare_packet.py', '--reference', str(self.files.paths[0]),
                '--reference-sha256', self.files.pins[0], '--output', str(output)]
        for rank in (0, 1):
            argv += ['--rank%d-evidence' % rank, str(self.files.paths[rank+1]),
                     '--rank%d-sha256' % rank, self.files.pins[rank+1]]
        with patch.object(sys, 'argv', argv), contextlib.redirect_stdout(io.StringIO()):
            helper.main()
        packet = json.loads(output.read_bytes())
        self.assertEqual(packet['files']['reference_stdout'],
                         dict(path=str(self.files.paths[0]), sha256=self.files.pins[0]))
        self.assertEqual(packet['request_id'], 'c7517799-2a77-49fa-af9c-2b4f662bf76c')

    def test_wrong_reference_pin_before_candidate_access(self):
        missing = [(self.files.root / 'missing0', '0'*64), (self.files.root / 'missing1', '1'*64)]
        with self.assertRaisesRegex(ValueError, 'reference_stdout pin'):
            helper.assemble(self.files.paths[0], '0'*64, missing)

    def test_short_reference_rejected_before_candidate_access(self):
        from audit_scope import AuditScope
        from fabricated import fixture, reference_bytes
        _, _, admitted, report, _, _ = fixture(AuditScope('registered_qwen38_27b', 32, 16, 128, 16),
                                               'c7517799-2a77-49fa-af9c-2b4f662bf76c')
        path = self.files.paths[0]
        path.write_bytes(reference_bytes(admitted, report))
        missing = [(self.files.root / 'missing0', '0'*64), (self.files.root / 'missing1', '1'*64)]
        with self.assertRaisesRegex(ValueError, 'reference admitted'):
            helper.assemble(path, helper.digest(path), missing)

    def test_reference_changed_after_validation_refused(self):
        import snapshot as module
        original = module.snapshot

        def changing(path, limit, **kwargs):
            result = original(path, limit, **kwargs)
            if Path(path) == self.files.paths[2]:
                with self.files.paths[0].open('ab') as stream:
                    stream.write(b' ')
            return result

        with patch.object(module, 'snapshot', side_effect=changing), self.assertRaisesRegex(ValueError, 'artifact recheck'):
            self.files.packet()


if __name__ == '__main__':
    unittest.main()
