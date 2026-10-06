#!/usr/bin/env python3
"""Offline tests of exact-byte metadata setup; no model or credential access."""
import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("fixture_setup", Path(__file__).with_name("prepare-mimo-prompt-fixtures.py"))
SETUP = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SETUP)


class FixtureSetupTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.corpus = self.root / "corpus.json"
        self.corpus.write_bytes(b"synthetic corpus\n")
        self.corpus_patch = patch.object(SETUP, "CORPUS_SHA256", hashlib.sha256(self.corpus.read_bytes()).hexdigest())
        self.corpus_patch.start()
        self.addCleanup(self.corpus_patch.stop)
        self.payloads = {name: (name + " fixture\n").encode() for name in SETUP.PINS}
        self.pins_patch = patch.object(SETUP, "PINS", {name: hashlib.sha256(data).hexdigest() for name, data in self.payloads.items()})
        self.pins_patch.start()
        self.addCleanup(self.pins_patch.stop)

    def test_all_allowlisted_files_are_exact_and_regular(self):
        calls = []
        def download(name):
            calls.append(name)
            return self.payloads[name]
        result = SETUP.prepare(self.root / "metadata", self.corpus, download)
        self.assertEqual(calls, list(self.payloads))
        self.assertEqual({p.name for p in result.iterdir()}, set(self.payloads))
        for name, data in self.payloads.items():
            self.assertEqual((result / name).read_bytes(), data)
            self.assertFalse((result / name).is_symlink())
            self.assertEqual((result / name).stat().st_mode & 0o777, 0o600)

    def test_wrong_download_hash_is_rejected(self):
        with self.assertRaises(ValueError):
            SETUP.prepare(self.root / "metadata", self.corpus, lambda _: b"wrong")

    def test_size_limit_is_not_a_truncation_success(self):
        with self.assertRaises(ValueError):
            SETUP.checked_bytes(b"four", hashlib.sha256(b"four").hexdigest(), 3)

    def test_existing_output_is_not_overwritten(self):
        output = self.root / "metadata"
        output.mkdir()
        with self.assertRaises(FileExistsError):
            SETUP.prepare(output, self.corpus, lambda _: self.fail("network must not run"))

    def test_linked_output_is_not_followed(self):
        output = self.root / "metadata"
        output.symlink_to(self.root / "absent", target_is_directory=True)
        with self.assertRaises(FileExistsError):
            SETUP.prepare(output, self.corpus, lambda _: self.fail("network must not run"))

    def test_linked_corpus_is_rejected(self):
        link = self.root / "linked.json"
        link.symlink_to(self.corpus)
        with self.assertRaises(ValueError):
            SETUP.prepare(self.root / "metadata", link, lambda _: self.fail("network must not run"))

    def test_changed_corpus_fails_before_download(self):
        self.corpus.write_bytes(b"changed")
        with self.assertRaises(ValueError):
            SETUP.prepare(self.root / "metadata", self.corpus, lambda _: self.fail("network must not run"))

    def test_unknown_names_cannot_download_weights(self):
        with patch.object(SETUP.urllib.request, "urlopen", side_effect=AssertionError("network")):
            with self.assertRaises(ValueError):
                SETUP.public_metadata("model.safetensors")


if __name__ == "__main__":
    unittest.main()
