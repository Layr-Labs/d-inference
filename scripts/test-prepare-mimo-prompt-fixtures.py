#!/usr/bin/env python3
"""Offline tests of exact-byte metadata setup; no model or credential access."""
import hashlib
import importlib.util
from pathlib import Path
import ssl
import tempfile
import unittest
from unittest.mock import patch
import urllib.error

SPEC = importlib.util.spec_from_file_location("fixture_setup", Path(__file__).with_name("prepare-mimo-prompt-fixtures.py"))
SETUP = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SETUP)


class Response:
    """A Hub response whose body may end early or fail as a cut TLS stream does."""

    def __init__(self, body, declared=None, url="https://huggingface.co/x", error=None):
        self.body, self.url, self.error = body, url, error
        self.headers = {} if declared is None else {"Content-Length": str(declared)}

    def __enter__(self):
        return self

    def __exit__(self, *_):
        return False

    def geturl(self):
        return self.url

    def read(self, size):
        if self.error is not None:
            raise self.error
        return self.body[:size]


def ssl_eof():
    return ssl.SSLEOFError(8, "[SSL: UNEXPECTED_EOF_WHILE_READING] EOF occurred in violation of protocol")


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

    def test_cache_serves_only_verified_bytes_and_keeps_only_verified_downloads(self):
        cache = self.root / "cache"
        calls = []
        def download(name):
            calls.append(name)
            return self.payloads[name]
        fetch = SETUP.cached(download, cache, SETUP.PINS.__getitem__)
        first = SETUP.prepare(self.root / "first", self.corpus, fetch)
        self.assertEqual(calls, list(self.payloads))
        self.assertEqual(sorted(path.name for path in cache.iterdir()), sorted(SETUP.PINS.values()))
        # A second run reads every file from the cache.
        second = SETUP.prepare(self.root / "second", self.corpus, fetch)
        self.assertEqual(calls, list(self.payloads))
        for name in self.payloads:
            self.assertEqual((second / name).read_bytes(), (first / name).read_bytes())
        # A corrupted entry is fetched again and replaced.
        name = next(iter(self.payloads))
        (cache / SETUP.PINS[name]).write_bytes(b"corrupted")
        SETUP.prepare(self.root / "third", self.corpus, fetch)
        self.assertEqual(calls, [*self.payloads, name])
        self.assertEqual((cache / SETUP.PINS[name]).read_bytes(), self.payloads[name])
        # A download with the wrong bytes is refused and never cached.
        empty = self.root / "empty-cache"
        with self.assertRaises(ValueError):
            SETUP.prepare(self.root / "fourth", self.corpus, SETUP.cached(lambda _: b"wrong", empty, SETUP.PINS.__getitem__))
        self.assertFalse(empty.exists())

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

    def network(self, *outcomes):
        return patch.object(SETUP.urllib.request, "urlopen", side_effect=list(outcomes))

    def test_cut_transfers_are_retried_with_backoff(self):
        name = next(iter(self.payloads))
        data = self.payloads[name]
        cases = {
            "short read": Response(data[:-1], len(data)),
            "TLS EOF mid-body": Response(b"", len(data), error=ssl_eof()),
            "TLS EOF on open": urllib.error.URLError(ssl_eof()),
            "connection reset": ConnectionResetError(54, "Connection reset by peer"),
            "socket timeout": TimeoutError("timed out"),
            "incomplete chunked body": SETUP.http.client.IncompleteRead(data[:4]),
            "HTTP 503": urllib.error.HTTPError("https://huggingface.co/x", 503, "Service Unavailable", {}, None),
        }
        for case, failure in cases.items():
            with self.subTest(case=case), self.network(failure, Response(data, len(data))) as urlopen, \
                    patch.object(SETUP.time, "sleep") as sleep:
                self.assertEqual(SETUP.public_metadata(name), data)
                self.assertEqual(urlopen.call_count, 2)
                sleep.assert_called_once_with(1)

    def test_three_short_reads_fail_after_three_attempts(self):
        name = next(iter(self.payloads))
        data = self.payloads[name]
        short = [Response(data[:-1], len(data)) for _ in range(3)]
        with self.network(*short, Response(data, len(data))) as urlopen, patch.object(SETUP.time, "sleep") as sleep:
            with self.assertRaisesRegex(SETUP.TransientTransfer, "ended before its Content-Length"):
                SETUP.public_metadata(name)
        self.assertEqual(urlopen.call_count, 3)
        self.assertEqual([call.args for call in sleep.call_args_list], [(1,), (3,)])

    def test_integrity_size_redirect_and_client_failures_are_not_retried(self):
        name = next(iter(self.payloads))
        data = self.payloads[name]
        # The oversize case declares more than the bound, so the short body is not a cut transfer.
        cases = {
            "full-size wrong digest": (Response(b"x" * len(data), len(data)), SETUP.MAXIMUM),
            "oversize body": (Response(b"x" * 9, 20), 8),
            "insecure redirect": (Response(data, len(data), url="http://huggingface.co/x"), SETUP.MAXIMUM),
            "HTTP 404": (urllib.error.HTTPError("https://huggingface.co/x", 404, "Not Found", {}, None),
                         SETUP.MAXIMUM),
        }
        for case, (failure, maximum) in cases.items():
            with self.subTest(case=case), self.network(failure, Response(data, len(data))) as urlopen, \
                    patch.object(SETUP, "MAXIMUM", maximum), patch.object(SETUP.time, "sleep") as sleep:
                with self.assertRaises((ValueError, urllib.error.HTTPError)):
                    SETUP.prepare(self.root / case.replace(" ", "-"), self.corpus, SETUP.public_metadata)
                self.assertEqual(urlopen.call_count, 1)
                sleep.assert_not_called()


if __name__ == "__main__":
    unittest.main()
