#!/usr/bin/env python3
"""Offline regression tests; no model, runtime, or remote asset downloads."""

import copy
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import ssl
import tempfile
import time
import unittest
from unittest.mock import patch
import urllib.error
import urllib.request

SCRIPT = Path(__file__).with_name("prepare-prompt-fixtures.py")
SPEC = importlib.util.spec_from_file_location("prompt_fixtures", SCRIPT)
fixtures = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(fixtures)
ROOT = SCRIPT.parent.parent


class Response(io.BytesIO):
    def __init__(self, body, url, length=None):
        super().__init__(body)
        self.url = url
        self.status = 200
        self.headers = {} if length is None else {"Content-Length": str(length)}


class CutResponse(Response):
    """Returns the first bytes of a body, then fails as a cut TLS stream does."""

    def __init__(self, prefix, url, error):
        super().__init__(prefix, url)
        self.error = error

    def read(self, size=-1):
        chunk = super().read(size)
        if chunk:
            return chunk
        raise self.error


class ScriptedOpener:
    """Plays one outcome per attempt: a response, or an exception raised by open."""

    def __init__(self, *outcomes):
        self.outcomes = list(outcomes)
        self.attempts = 0

    def open(self, url, timeout):
        self.attempts += 1
        outcome = self.outcomes.pop(0)
        if isinstance(outcome, BaseException):
            raise outcome
        return outcome


def ssl_eof():
    return ssl.SSLEOFError(8, "[SSL: UNEXPECTED_EOF_WHILE_READING] EOF occurred in violation of protocol")


class Opener:
    def __init__(self, body):
        self.body = body
        self.urls = []

    def open(self, url, timeout):
        self.urls.append(url)
        return Response(self.body, url, len(self.body))


class PromptFixturesTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.source = self.root / "manifests"
        self.source.mkdir()
        self.body = b'{"model_type":"test"}'
        self.artifact = {
            "path": "config.json", "role": "config", "size_bytes": len(self.body),
            "sha256": hashlib.sha256(self.body).hexdigest(),
        }
        self.manifest = {
            "schema_version": 1, "model_id": "public/test", "r2_prefix": "v2/test/2026-09-09-r1",
            "files": [self.artifact, {
                "path": "weights.safetensors", "role": "weight", "size_bytes": 10**12,
                "sha256": "a" * 64,
            }],
        }
        self.aggregate(self.manifest)

    def tearDown(self):
        for directory, _, _ in fixtures.os.walk(self.root):
            Path(directory).chmod(0o700)
        self.temporary.cleanup()

    def aggregate(self, manifest):
        manifest["aggregate_sha256"] = hashlib.sha256(b"".join(
            bytes.fromhex(item["sha256"]) for item in sorted(manifest["files"], key=lambda a: a["path"])
        )).hexdigest()

    def write_manifest(self):
        raw = json.dumps(self.manifest).encode()
        (self.source / "test.json").write_bytes(raw)
        return raw

    def provision(self, output="output"):
        return fixtures.provision(self.source, self.root / "artifacts", self.root / output,
                                  "https://models.example.test")

    def test_real_pinned_manifests_match_committed_contract_ids(self):
        vectors = json.loads((ROOT / "fixtures/prompt-contract/v1/production_vectors.json").read_bytes())
        expected = {model["model_id"]: model["prompt_contract_id"] for model in vectors["models"]}
        actual = {}
        for path in (ROOT / "fixtures/prompt-contract/v1/manifests").glob("*.json"):
            manifest = json.loads(path.read_bytes())
            actual[manifest["model_id"]] = fixtures.contract_id(fixtures.validate_manifest(manifest))
        self.assertEqual(actual, expected)
        for path in (ROOT / "fixtures/prompt-contract/nemotron/manifests").glob("*.json"):
            self.assertTrue(fixtures.validate_manifest(json.loads(path.read_bytes())))

    def test_provisions_only_prompt_assets_and_reverifies_cache(self):
        raw = self.write_manifest()
        opener = Opener(self.body)
        with patch.object(fixtures.urllib.request, "build_opener", return_value=opener):
            self.assertEqual(self.provision(), 1)
            self.assertEqual(self.provision("second"), 1)
        self.assertEqual(opener.urls, ["https://models.example.test/v2/test/2026-09-09-r1/config.json"])
        identity = fixtures.contract_id([self.artifact])
        contract = self.root / "artifacts" / identity
        self.assertEqual((contract / "config.json").read_bytes(), self.body)
        self.assertEqual((contract / "config.json").stat().st_mode & 0o777, 0o400)
        self.assertEqual(contract.stat().st_mode & 0o777, 0o500)
        metadata = json.loads((contract / "prompt-contract.json").read_bytes())
        self.assertEqual(metadata["prompt_contract_id"], identity)
        self.assertEqual(metadata["versions"], fixtures.VERSIONS)
        self.assertEqual(next((self.root / "output").iterdir()).read_bytes(), raw)
        (contract / "config.json").chmod(0o600)
        (contract / "config.json").write_bytes(b"corrupt")
        with self.assertRaisesRegex(ValueError, "cached artifact"):
            self.provision("third")

    def test_identifies_public_fixture_client_to_cdn(self):
        self.write_manifest()
        opener = Opener(self.body)
        with patch.object(fixtures.urllib.request, "build_opener", return_value=opener):
            self.provision()
        self.assertEqual(opener.addheaders, [("User-Agent", "darkbloom-prompt-fixtures/1")])

    def test_rejects_unsafe_paths_digests_aggregates_and_budgets(self):
        for path in ("/absolute", "../escape", "a/../b", "a//b", "a\\b", "a/./b", "a\0b"):
            with self.subTest(path=path), self.assertRaises(ValueError):
                fixtures.relative_path(path)
        for mutation in ("digest", "aggregate", "size", "total", "duplicate", "reserved"):
            manifest = copy.deepcopy(self.manifest)
            if mutation == "digest":
                manifest["files"][0]["sha256"] = "A" * 64
            elif mutation == "aggregate":
                manifest["aggregate_sha256"] = "0" * 64
            elif mutation == "size":
                manifest["files"][0]["size_bytes"] = fixtures.MAX_ARTIFACT_BYTES + 1
            elif mutation == "total":
                manifest["files"] = [dict(self.artifact, path=f"config{i}.json",
                                          size_bytes=fixtures.MAX_ARTIFACT_BYTES) for i in range(5)]
                self.aggregate(manifest)
            elif mutation == "duplicate":
                manifest["files"].append(dict(self.artifact))
            else:
                manifest["files"][0]["path"] = "prompt-contract.json"
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                fixtures.validate_manifest(manifest)

    def fetch(self, opener, deadline=None):
        output = self.root / "download"
        try:
            fixtures.download(opener, "https://models.example.test/a", output, self.artifact,
                              time.monotonic() + 120 if deadline is None else deadline)
            return output.read_bytes()
        finally:
            output.unlink(missing_ok=True)

    def test_download_fails_at_once_on_tampering_overflow_origin_and_status(self):
        url = "https://models.example.test/a"
        wrong = Response(b"x" * len(self.body), url)
        accepted = Response(self.body, url)
        accepted.status = 206
        cases = {
            "SHA-256 mismatch": wrong,
            "exceeds declared size": Response(self.body + b"x", url),
            "cross-origin": Response(self.body, "https://other.test/a"),
            "Content-Length mismatch": Response(self.body, url, 1),
            "HTTP 200": accepted,
            "Not Found": urllib.error.HTTPError(url, 404, "Not Found", {}, None),
        }
        for message, outcome in cases.items():
            opener = ScriptedOpener(outcome, Response(self.body, url))
            with self.subTest(message=message), patch.object(fixtures.time, "sleep") as sleep:
                with self.assertRaisesRegex((ValueError, urllib.error.HTTPError), message):
                    self.fetch(opener)
                self.assertEqual(opener.attempts, 1)
                sleep.assert_not_called()

    def test_download_retries_cut_transfers_with_backoff(self):
        url = "https://models.example.test/a"
        server_error = Response(b"", url)
        server_error.status = 502
        cases = {
            "short read": Response(self.body[:-1], url),
            "TLS EOF mid-body": CutResponse(self.body[:4], url, ssl_eof()),
            "TLS EOF on open": urllib.error.URLError(ssl_eof()),
            "connection reset": ConnectionResetError(54, "Connection reset by peer"),
            "socket timeout": TimeoutError("timed out"),
            "incomplete chunked body": fixtures.http.client.IncompleteRead(self.body[:4]),
            "HTTP 503": urllib.error.HTTPError(url, 503, "Service Unavailable", {}, None),
            "HTTP 502 status": server_error,
        }
        for name, failure in cases.items():
            opener = ScriptedOpener(failure, Response(self.body, url))
            with self.subTest(name=name), patch.object(fixtures.time, "sleep") as sleep:
                self.assertEqual(self.fetch(opener), self.body)
                self.assertEqual(opener.attempts, 2)
                sleep.assert_called_once_with(1)

    def test_download_gives_up_after_three_short_reads(self):
        url = "https://models.example.test/a"
        opener = ScriptedOpener(*(Response(self.body[:-1], url) for _ in range(3)), Response(self.body, url))
        with patch.object(fixtures.time, "sleep") as sleep:
            with self.assertRaisesRegex(fixtures.TransientTransfer, "ended before its declared size"):
                self.fetch(opener)
        self.assertEqual(opener.attempts, 3)
        self.assertEqual([call.args for call in sleep.call_args_list], [(1,), (3,)])

    def test_download_retries_stay_inside_the_deadline(self):
        url = "https://models.example.test/a"
        opener = ScriptedOpener(urllib.error.URLError(ssl_eof()), Response(self.body, url))
        with patch.object(fixtures.time, "sleep") as sleep:
            # The 1 s backoff would end after the deadline: stop instead of sleeping.
            with self.assertRaisesRegex(ValueError, "timed out"):
                self.fetch(opener, time.monotonic() + 0.5)
            self.assertEqual(opener.attempts, 1)
            with self.assertRaisesRegex(ValueError, "timed out"):
                self.fetch(ScriptedOpener(), time.monotonic() - 1)
        sleep.assert_not_called()

    def test_download_never_deletes_an_output_it_did_not_create(self):
        output = self.root / "download"
        output.write_bytes(b"other")
        opener = ScriptedOpener(Response(self.body, "https://models.example.test/a"))
        with patch.object(fixtures.time, "sleep") as sleep, self.assertRaises(FileExistsError):
            fixtures.download(opener, "https://models.example.test/a", output, self.artifact,
                              time.monotonic() + 120)
        self.assertEqual(output.read_bytes(), b"other")
        sleep.assert_not_called()

    def test_redirect_policy_and_url_restrictions(self):
        for url in ("http://example.test", "https://user:pass@example.test", "https://example.test/?q=1",
                    "https://example.test/#fragment", "file:///tmp/x"):
            with self.subTest(url=url), self.assertRaises(ValueError):
                fixtures.https_url(url)
        request = urllib.request.Request("https://models.example.test/a")
        handler = fixtures.SameOriginRedirect()
        with self.assertRaises(ValueError):
            handler.redirect_request(request, None, 302, "", {}, "https://other.test/a")
        redirect = handler.redirect_request(request, None, 302, "", {}, "https://models.example.test/b")
        self.assertEqual(redirect.full_url, "https://models.example.test/b")

    def test_manifest_and_directory_restrictions_precede_downloads(self):
        self.write_manifest()
        with patch.object(fixtures.urllib.request, "build_opener") as network:
            (self.source / "extra.txt").write_text("unexpected")
            with self.assertRaises(ValueError):
                self.provision()
            network.assert_not_called()
        (self.source / "extra.txt").unlink()
        (self.source / "duplicate.json").write_bytes((self.source / "test.json").read_bytes())
        with self.assertRaisesRegex(ValueError, "duplicate model"):
            self.provision()
        (self.source / "duplicate.json").unlink()
        target = self.root / "link"
        target.symlink_to(self.source, target_is_directory=True)
        with self.assertRaises(ValueError):
            fixtures.safe_directory(target)
        (self.source / "test.json").unlink()
        (self.source / "test.json").symlink_to(SCRIPT)
        with self.assertRaises(ValueError):
            self.provision()

    def test_failed_download_is_not_published(self):
        self.write_manifest()
        with patch.object(fixtures.urllib.request, "build_opener", return_value=Opener(b"bad")):
            with self.assertRaises(ValueError):
                self.provision()
        self.assertEqual(list((self.root / "artifacts").iterdir()), [])
        self.assertEqual(list((self.root / "output").iterdir()), [])


if __name__ == "__main__":
    unittest.main()
