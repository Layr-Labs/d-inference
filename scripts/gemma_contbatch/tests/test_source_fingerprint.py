"""Dirty source identity uses filename bytes, including Git-quoted names."""

from pathlib import Path
import subprocess
import tempfile
import unittest

from ..process import source_fingerprint


class SourceFingerprintTests(unittest.TestCase):
    def test_untracked_kernel_content_changes_fingerprint_for_quoted_names(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            subprocess.run(["git", "-C", str(root), "-c", "core.hooksPath=/dev/null",
                            "-c", "commit.gpgsign=false", "-c", "user.name=Fixture",
                            "-c", "user.email=fixture@example.invalid",
                            "commit", "-q", "--allow-empty", "-m", "fixture"], check=True)
            for name in ('plain.metal', 'kernel"variant.metal', 'café.metal', 'line\nbreak.metal', 'tab\tname.metal'):
                with self.subTest(name=name):
                    source = root / name
                    source.write_bytes(b"before")
                    status, before = source_fingerprint(root)
                    self.assertTrue(status)
                    source.write_bytes(b"after!")
                    after_status, after = source_fingerprint(root)
                    self.assertEqual(status, after_status)
                    self.assertNotEqual(before, after)
                    self.assertEqual(after, source_fingerprint(root)[1])
                    source.unlink()
