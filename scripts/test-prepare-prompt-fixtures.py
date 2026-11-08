#!/usr/bin/env python3
"""Offline regression tests; no model, runtime, or remote asset downloads."""

import contextlib
import copy
import hashlib
import importlib.util
import io
import json
import os
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
# The script imports its cache from scripts/, which is sys.path[0] here too.
import verified_download_cache  # noqa: E402


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


class FailingReader(io.BytesIO):
    """A cache entry whose first read returns bytes and whose next read fails, as a bad disk does."""

    def read(self, size=-1):
        if self.tell():
            raise OSError(5, "Input/output error")
        return super().read(1)


class FailingReadsOS:
    """The os module as the cache sees it, with every opened entry failing on its second read."""

    def __init__(self, body):
        self.body = body

    def __getattr__(self, name):
        return getattr(os, name)

    def fdopen(self, fd, mode):
        os.close(fd)
        return FailingReader(self.body)


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

    def provision(self, output="output", artifacts="artifacts", download_cache=None):
        return fixtures.provision(self.source, self.root / artifacts, self.root / output,
                                  "https://models.example.test", download_cache)

    def provision_cached(self, opener, run):
        """One CI run: a fresh artifact root and output, the shared download cache."""
        with patch.object(fixtures.urllib.request, "build_opener", return_value=opener), \
                contextlib.redirect_stdout(io.StringIO()) as report:
            self.assertEqual(self.provision(f"output-{run}", f"artifacts-{run}", self.root / "cache"), 1)
        contract = self.root / f"artifacts-{run}" / fixtures.contract_id([self.artifact])
        self.assertEqual((contract / "config.json").read_bytes(), self.body)
        self.assertEqual((contract / "config.json").stat().st_mode & 0o777, 0o400)
        return report.getvalue()

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

    def test_download_cache_supplies_verified_artifacts_without_the_network(self):
        self.write_manifest()
        opener = Opener(self.body)
        first = self.provision_cached(opener, 1)
        entry = self.root / "cache" / self.artifact["sha256"]
        self.assertEqual(entry.read_bytes(), self.body)
        self.assertIn("public/test: 0 of 1 artifacts from the download cache, 1 downloaded "
                      f"({len(self.body)} bytes)", first)
        second = self.provision_cached(opener, 2)
        self.assertEqual(len(opener.urls), 1)
        self.assertIn("public/test: 1 of 1 artifacts from the download cache, 0 downloaded (0 bytes)", second)

    def test_invalid_download_cache_entries_are_downloaded_and_replaced(self):
        self.write_manifest()
        cache = self.root / "cache"
        entry = cache / self.artifact["sha256"]
        valid = self.root / "valid"
        valid.write_bytes(self.body)

        def tampered():
            entry.write_bytes(b"x" * len(self.body))

        def short():
            entry.write_bytes(self.body[:-1])

        def long():
            entry.write_bytes(self.body + b"x")

        def linked():
            entry.symlink_to(valid)

        def directory():
            entry.mkdir()

        def fifo():
            os.mkfifo(entry)

        for run, damage in enumerate((tampered, short, long, linked, directory, fifo)):
            with self.subTest(entry=damage.__name__):
                cache.mkdir(exist_ok=True)
                damage()
                opener = Opener(self.body)
                with patch.object(verified_download_cache, "print", create=True) as warning:
                    report = self.provision_cached(opener, run)
                self.assertEqual(len(opener.urls), 1)
                self.assertIn("0 of 1 artifacts from the download cache, 1 downloaded", report)
                if damage is directory:
                    # A directory cannot be replaced by a file: the run still passes.
                    self.assertIn("not stored", warning.call_args.args[0])
                    entry.rmdir()
                else:
                    warning.assert_not_called()
                    self.assertFalse(entry.is_symlink())
                    self.assertEqual(entry.read_bytes(), self.body)
                    entry.unlink()
        self.assertEqual(valid.read_bytes(), self.body)
        self.assertEqual([path.name for path in cache.iterdir()], [])

    def test_a_cache_read_error_downloads_instead(self):
        self.write_manifest()
        (self.root / "cache").mkdir()
        (self.root / "cache" / self.artifact["sha256"]).write_bytes(self.body)
        opener = Opener(self.body)
        with patch.object(verified_download_cache, "os", FailingReadsOS(self.body)):
            report = self.provision_cached(opener, 1)
        self.assertEqual(len(opener.urls), 1)
        self.assertIn("0 of 1 artifacts from the download cache, 1 downloaded", report)
        # The download then replaced the entry it could not read.
        self.assertEqual((self.root / "cache" / self.artifact["sha256"]).read_bytes(), self.body)

    def test_a_cache_that_cannot_store_never_fails_provisioning(self):
        self.write_manifest()
        (self.root / "cache").write_bytes(b"not a directory")
        opener = Opener(self.body)
        with patch.object(verified_download_cache, "print", create=True) as warning:
            self.provision_cached(opener, 1)
        self.assertIn(f"download cache: entry {self.artifact['sha256']} not stored", warning.call_args.args[0])
        self.assertEqual((self.root / "cache").read_bytes(), b"not a directory")

    def test_cache_restore_never_replaces_an_existing_output(self):
        cache = self.root / "cache"
        cache.mkdir()
        (cache / self.artifact["sha256"]).write_bytes(self.body)
        output = self.root / "existing"
        output.write_bytes(b"other")
        with self.assertRaises(FileExistsError):
            verified_download_cache.restore_file(cache, self.artifact["sha256"], len(self.body), output)
        self.assertEqual(output.read_bytes(), b"other")

    def test_download_deadline_scales_with_the_missing_bytes_and_stays_bounded(self):
        self.assertEqual(fixtures.download_seconds(0), 120)
        self.assertEqual(fixtures.download_seconds(17 << 20), 120 + 17 * 8)
        self.assertEqual(fixtures.download_seconds(fixtures.MAX_CONTRACT_BYTES), 900)
        # Only the bytes the cache did not supply count toward the deadline.
        large = {"path": "tokenizer.json", "role": "tokenizer", "size_bytes": 32 << 20, "sha256": "b" * 64}
        self.manifest["files"].append(large)
        self.aggregate(self.manifest)
        self.write_manifest()
        cache = self.root / "cache"
        cache.mkdir()
        (cache / self.artifact["sha256"]).write_bytes(self.body)
        deadlines = []

        def download(opener, url, output, artifact, deadline):
            deadlines.append((artifact["path"], deadline - fixtures.time.monotonic()))
            raise ValueError("stop after the deadline is set")

        with patch.object(fixtures, "download", download), self.assertRaisesRegex(ValueError, "stop"):
            self.provision(download_cache=cache)
        [(path, seconds)] = deadlines
        self.assertEqual(path, "tokenizer.json")
        self.assertAlmostEqual(seconds, 120 + 32 * 8, delta=5)
        self.assertEqual(list((self.root / "artifacts").iterdir()), [])

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
