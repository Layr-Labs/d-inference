#!/usr/bin/env python3
"""Offline tests of the MiMo audio codec download: no network, no model."""
import hashlib
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("audio_setup", Path(__file__).with_name("prepare-mimo-audio-fixtures.py"))
SETUP = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SETUP)

BODY = bytes(range(256)) * 64


class Curl:
    """Each call appends up to `per_call` bytes of BODY to the output, as an
    attempt cut by --max-time does (exit 28), and resumes only with
    --continue-at -. `fail_codes` fail the first calls before any byte."""

    def __init__(self, per_call, fail_codes=()):
        self.per_call, self.fail_codes, self.calls = per_call, list(fail_codes), []

    def __call__(self, args, **_):
        self.calls.append(args)
        if self.fail_codes:
            return subprocess.CompletedProcess(args, self.fail_codes.pop(0))
        output = Path(args[args.index("--output") + 1])
        have = output.stat().st_size if output.exists() and "--continue-at" in args else 0
        chunk = BODY[have:have + self.per_call]
        with output.open("ab" if have else "wb") as stream:
            stream.write(chunk)
        return subprocess.CompletedProcess(args, 0 if have + len(chunk) == len(BODY) else 28)


class DownloadTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.target = Path(self.directory.name) / "model.safetensors.download"
        self.sleep = patch.object(SETUP.time, "sleep").start()
        self.addCleanup(patch.stopall)
        self.addCleanup(self.directory.cleanup)

    def test_each_attempt_resumes_the_partial_file(self):
        curl = Curl(per_call=len(BODY) // 3 + 1)
        with patch.object(SETUP.subprocess, "run", curl):
            SETUP.download("https://example.invalid/codec", self.target, len(BODY))
        self.assertEqual(self.target.read_bytes(), BODY)
        self.assertEqual(len(curl.calls), 3)
        for args in curl.calls:
            self.assertEqual(args[args.index("--continue-at") + 1], "-")
            self.assertNotIn("--retry", args)

    def test_an_error_before_any_byte_is_retried(self):
        curl = Curl(per_call=len(BODY), fail_codes=[6])
        with patch.object(SETUP.subprocess, "run", curl):
            SETUP.download("https://example.invalid/codec", self.target, len(BODY))
        self.assertEqual(self.target.read_bytes(), BODY)
        self.assertEqual(len(curl.calls), 2)

    def test_it_stops_after_the_last_attempt(self):
        curl = Curl(per_call=1)
        with patch.object(SETUP.subprocess, "run", curl), self.assertRaises(subprocess.CalledProcessError):
            SETUP.download("https://example.invalid/codec", self.target, len(BODY))
        self.assertEqual(len(curl.calls), SETUP.DOWNLOAD_ATTEMPTS)

    def test_a_partial_longer_than_the_file_starts_over(self):
        self.target.write_bytes(b"x" * (len(BODY) + 1))
        curl = Curl(per_call=len(BODY))
        with patch.object(SETUP.subprocess, "run", curl):
            SETUP.download("https://example.invalid/codec", self.target, len(BODY))
        self.assertEqual(self.target.read_bytes(), BODY)

    def test_a_digest_mismatch_removes_the_partial(self):
        cache = Path(self.directory.name) / "cache"
        files = {"audio_tokenizer/model.safetensors": (len(BODY), hashlib.sha256(b"other").hexdigest())}
        curl = Curl(per_call=len(BODY))
        with patch.object(SETUP, "FILES", files), patch.object(SETUP.subprocess, "run", curl), \
                self.assertRaises(ValueError):
            SETUP.prepare(cache, Path(self.directory.name) / "out")
        self.assertFalse((cache / "audio_tokenizer/model.safetensors.download").exists())
        self.assertFalse((cache / "audio_tokenizer/model.safetensors").exists())


if __name__ == "__main__":
    unittest.main()
