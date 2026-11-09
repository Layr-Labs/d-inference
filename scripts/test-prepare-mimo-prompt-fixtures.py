#!/usr/bin/env python3
"""Offline tests of exact-byte metadata setup; no model or credential access."""
import copy
import email.message
import hashlib
import importlib.util
import io
from pathlib import Path
import ssl
import tempfile
import unittest
from unittest.mock import patch
import urllib.error
import urllib.request
import urllib.response

import fixture_redirects

SPEC = importlib.util.spec_from_file_location("fixture_setup", Path(__file__).with_name("prepare-mimo-prompt-fixtures.py"))
SETUP = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SETUP)


class Response:
    """A Hub response whose body may end early or fail as a cut TLS stream does."""

    def __init__(self, body, declared=None, error=None):
        self.body, self.error = body, error
        self.headers = {} if declared is None else {"Content-Length": str(declared)}

    def __enter__(self):
        return self

    def __exit__(self, *_):
        return False

    def read(self, size):
        if self.error is not None:
            raise self.error
        return self.body[:size]


def ssl_eof():
    return ssl.SSLEOFError(8, "[SSL: UNEXPECTED_EOF_WHILE_READING] EOF occurred in violation of protocol")


class Origins(urllib.request.BaseHandler):
    """Answers every HTTP and HTTPS request from a fixed route table and records it.

    The script's own redirect handler runs on these answers, as it does on the Hub's.
    """

    handler_order = 100  # Before urllib's own HTTP and HTTPS handlers.

    def __init__(self, routes):
        self.routes, self.requested = routes, []

    def answer(self, request):
        self.requested.append(request.full_url)
        status, value = self.routes[request.full_url]
        headers = email.message.Message()
        body = value if status == 200 else b""
        if status != 200:
            headers["Location"] = value
        headers["Content-Length"] = str(len(body))
        response = urllib.response.addinfourl(io.BytesIO(body), headers, request.full_url, status)
        response.msg = "OK" if status == 200 else "Found"
        return response

    http_open = https_open = answer


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
        with patch.object(SETUP.OPENER, "open", side_effect=AssertionError("network")):
            with self.assertRaises(ValueError):
                SETUP.public_metadata("model.safetensors")

    def network(self, *outcomes):
        return patch.object(SETUP.OPENER, "open", side_effect=list(outcomes))

    def redirected(self, location, *routes):
        """Fetch the first pinned file through the script's redirect handler.

        The Hub answers its URL with a 302 to location; routes answer the later
        hops. self.requested keeps every URL that was requested, in order.
        """
        name = next(iter(self.payloads))
        url = f"https://huggingface.co/{SETUP.REPOSITORY}/resolve/{SETUP.REVISION}/{name}"
        origins = Origins({url: (302, location), **dict(routes)})
        self.requested = origins.requested
        redirects = next(h for h in SETUP.OPENER.handlers if isinstance(h, SETUP.OriginRedirect))
        opener = urllib.request.build_opener(copy.copy(redirects), origins)
        with patch.object(SETUP, "OPENER", opener), patch.object(SETUP.time, "sleep") as sleep:
            try:
                return SETUP.public_metadata(name)
            finally:
                sleep.assert_not_called()

    def test_same_origin_and_hugging_face_cdn_redirects_are_followed(self):
        data = next(iter(self.payloads.values()))
        hub = "https://huggingface.co"
        cases = {
            "same-origin resolve cache": f"{hub}/api/resolve-cache/models/x/config.json?etag=1",
            "same origin, explicit port": "https://huggingface.co:443/api/resolve-cache/x",
            "Xet bridge CDN": "https://us.aws.cdn.hf.co/xet-bridge-us/a/b?Expires=1&Signature=s",
            "Xet CAS bridge": "https://cas-bridge.xethub.hf.co/xet-bridge-us/a/b?X-Amz-Signature=s",
            "LFS CDN": "https://cdn-lfs-us-1.hf.co/repos/a/b?Expires=1",
            "CDN apex": "https://hf.co/a",
        }
        for case, location in cases.items():
            with self.subTest(case=case):
                self.assertEqual(self.redirected(location, (location, (200, data))), data)
                self.assertEqual(self.requested[1:], [location])

    def test_other_redirects_fail_at_once_without_requesting_the_target(self):
        cases = {
            "plain-HTTP CDN": "http://us.aws.cdn.hf.co/xet-bridge-us/a",
            "plain-HTTP downgrade": "http://huggingface.co/a",
            "another host": "https://evil.example/a",
            "another port": "https://huggingface.co:8443/a",
            "CDN on another port": "https://us.aws.cdn.hf.co:8443/a",
            "CDN with credentials": "https://user:secret@us.aws.cdn.hf.co/a",
            "CDN name as a prefix": "https://hf.co.evil.example/a",
            "CDN name without a dot": "https://evilhf.co/a",
            "Hub name as a CDN": "https://huggingface.co.hf.co.evil.example/a",
        }
        for case, location in cases.items():
            with self.subTest(case=case):
                with self.assertRaisesRegex(ValueError, "another origin"):
                    self.redirected(location)
                # The target is never requested, and redirected() asserts no retry.
                self.assertEqual(len(self.requested), 1)

    def test_the_cdn_allowance_covers_only_the_hub_hop(self):
        cdn = "https://us.aws.cdn.hf.co/xet-bridge-us/a"
        # A CDN host may not send the download on to another host, CDN or not.
        for onward in ("https://evil.example/a", "https://cas-bridge.xethub.hf.co/a"):
            with self.subTest(onward=onward):
                with self.assertRaisesRegex(ValueError, "another origin"):
                    self.redirected(cdn, (cdn, (302, onward)))
                self.assertEqual(self.requested[1:], [cdn])
        # Only a redirect from https://huggingface.co may reach a CDN host.
        for source in ("http://huggingface.co/a", "https://huggingface.co:8443/a", "https://hf.co/a",
                       "https://models.darkbloom.ai/a"):
            with self.subTest(source=source):
                self.assertFalse(fixture_redirects.redirect_allowed(source, cdn, hugging_face_cdn=True))

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
