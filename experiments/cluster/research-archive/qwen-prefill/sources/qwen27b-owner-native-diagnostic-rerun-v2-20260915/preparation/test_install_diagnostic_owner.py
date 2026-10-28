"""Temporary-file checks only; no actual device path, process, SSH or binary execution."""
from pathlib import Path
import base64
import fcntl
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import install_diagnostic_owner as subject

BASE = Path(__file__).resolve().parents[1]


class InstallChecks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='diagnostic-owner-install-')
        self.root = Path(self.temp.name).resolve()
        self.root.chmod(0o700)
        (self.root / 'evidence').mkdir(mode=0o700)
        self.device = self.root / 'device'; self.device.mkdir(mode=0o700)
        self.journal = self.device / 'native-device.lease'; self.journal.write_bytes(b''); self.journal.chmod(0o600)
        self.old = (BASE.parent / 'owner-retirement-controls-build-20260915/bundle-qwen27b/darkbloom-owner-qualification').read_bytes()
        self.new = (BASE.parent / 'qwen27b-owner-native-diagnostics-20260915/bundle/darkbloom-owner-qualification').read_bytes()
        self.target = self.root / subject.NAME; self.target.write_bytes(self.old); self.target.chmod(0o755)
        (self.root / 'owner.json').write_bytes((BASE / 'configuration/owner-rank0.json').read_bytes())
        (self.root / 'owner.json').chmod(0o600)
        self.packet = {'schema': 'qwen27b_native_diagnostic_owner_install_v1', 'rank': 0,
                       'binaryBase64': base64.b64encode(self.new).decode()}

    def tearDown(self):
        self.temp.cleanup()

    def invoke(self, observe=lambda: None):
        return subject.install(self.packet, self.root, self.journal, observe)

    def refused(self, observe=lambda: None):
        with self.assertRaises((AssertionError, OSError, ValueError)):
            self.invoke(observe)

    def test_success_backups_and_preserves_journal_inode(self):
        inode = self.journal.stat().st_ino
        observations = []
        result = self.invoke(lambda: observations.append(True))
        self.assertEqual(len(observations), 2)
        self.assertEqual(self.target.read_bytes(), self.new)
        self.assertEqual((self.root / subject.BACKUP).read_bytes(), self.old)
        self.assertEqual(self.journal.stat().st_ino, inode)
        self.assertEqual(self.journal.read_bytes(), b'')
        self.assertFalse(result['configurationChanged'])

    def test_nonempty_or_locked_journal_refuses(self):
        self.journal.write_bytes(b'unknown')
        self.refused()
        self.journal.write_bytes(b'')
        with self.journal.open('rb') as held:
            fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.refused()
        self.assertEqual(self.target.read_bytes(), self.old)

    def test_wrong_old_or_new_binary_refuses(self):
        self.target.write_bytes(b'unknown')
        self.refused()
        self.target.write_bytes(self.old)
        self.packet['binaryBase64'] = base64.b64encode(self.old).decode()
        self.refused()

    def test_symlink_or_hardlinked_owner_refuses(self):
        renamed = self.root / 'old'; self.target.rename(renamed)
        self.target.symlink_to(renamed); self.refused(); self.target.unlink()
        os.link(renamed, self.target); self.refused()

    def test_existing_backup_or_evidence_refuses(self):
        (self.root / subject.BACKUP).write_bytes(b'prior')
        self.refused()
        (self.root / subject.BACKUP).unlink()
        (self.root / 'evidence/prior.json').write_bytes(b'{}')
        self.refused()
        self.assertEqual(self.target.read_bytes(), self.old)

    def test_live_observation_refuses_before_backup(self):
        def live():
            raise AssertionError('fabricated live owner')
        self.refused(live)
        self.assertFalse((self.root / subject.BACKUP).exists())

    def test_changed_owner_at_second_observation_refuses(self):
        calls = []
        def change():
            calls.append(True)
            if len(calls) == 2:
                self.target.write_bytes(b'changed')
        self.refused(change)
        self.assertEqual(self.target.read_bytes(), b'changed')
        self.assertEqual((self.root / subject.BACKUP).read_bytes(), self.old)

    def test_wrong_rank_configuration_and_extra_key_refuse(self):
        self.packet['rank'] = 1; self.refused()
        self.packet['rank'] = 0; self.packet['path'] = '/arbitrary'; self.refused()

    def test_mutated_temporary_refuses_and_preserves_old(self):
        calls = []
        def change():
            calls.append(True)
            if len(calls) == 2:
                (self.root / subject.TEMPORARY).write_bytes(b'changed')
        self.refused(change)
        self.assertEqual(self.target.read_bytes(), self.old)

    def test_swapped_temporary_refuses_and_preserves_old(self):
        calls = []
        def change():
            calls.append(True)
            if len(calls) == 2:
                temporary = self.root / subject.TEMPORARY
                temporary.rename(self.root / 'retained-original-temporary')
                temporary.write_bytes(self.new)
                temporary.chmod(0o755)
        self.refused(change)
        self.assertEqual(self.target.read_bytes(), self.old)

    def test_changed_backup_refuses_and_preserves_old(self):
        calls = []
        def change():
            calls.append(True)
            if len(calls) == 2:
                (self.root / subject.BACKUP).write_bytes(b'changed')
        self.refused(change)
        self.assertEqual(self.target.read_bytes(), self.old)


if __name__ == '__main__':
    unittest.main()
