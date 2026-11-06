#!/usr/bin/env python3
"""CPU checks for metadata authentication and actual deterministic PNG pixels."""
import hashlib
import importlib.util
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest
from unittest import mock
import urllib.parse
import zlib

SPEC = importlib.util.spec_from_file_location(
    "fixtures", Path(__file__).with_name("prepare-mimo-image-http-fixtures.py"))
F = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(F)


class Curl:
    """Plays one curl outcome per call: (exit code, "--write-out" text, body written to --output).

    The write-out text is the HTTP status, then the redirect URL for a redirect.
    """

    def __init__(self, *outcomes):
        self.outcomes = list(outcomes)
        self.argv = []

    def __call__(self, argv, **_):
        self.argv.append(argv)
        code, status, body = self.outcomes.pop(0)
        if body is not None:
            Path(argv[argv.index("--output") + 1]).write_bytes(body)
        return subprocess.CompletedProcess(argv, code, status, "")


class FixtureTests(unittest.TestCase):
    def test_real_pixels_and_chunk_integrity(self):
        for rgb in ((255, 0, 0), (0, 0, 255)):
            data = F.png(rgb)
            self.assertEqual(data[:8], b"\x89PNG\r\n\x1a\n")
            position, kinds = 8, []
            while position < len(data):
                size = struct.unpack(">I", data[position:position + 4])[0]
                kind = data[position + 4:position + 8]
                payload = data[position + 8:position + 8 + size]
                crc = struct.unpack(">I", data[position + 8 + size:position + 12 + size])[0]
                self.assertEqual(crc, zlib.crc32(kind + payload))
                kinds.append(kind)
                if kind == b"IHDR":
                    self.assertEqual(struct.unpack(">IIBBBBB", payload), (28, 28, 8, 2, 0, 0, 0))
                if kind == b"IDAT":
                    self.assertEqual(zlib.decompress(payload), (b"\0" + bytes(rgb) * 28) * 28)
                position += 12 + size
            self.assertEqual(kinds, [b"IHDR", b"IDAT", b"IEND"])
            self.assertEqual(position, len(data))
        self.assertNotEqual(F.png((255, 0, 0)), F.png((0, 0, 255)))

    def test_cached_metadata_is_used_only_when_its_bytes_match_the_pin(self):
        payloads = {name: f"{name} fixture\n".encode() for name in F.NAMES}
        pins = {name: (len(data), hashlib.sha256(data).hexdigest()) for name, data in payloads.items()}
        calls = []
        def fetch(name):
            calls.append(name)
            return payloads[name]
        with tempfile.TemporaryDirectory() as root, mock.patch.dict(F.PINS.FILES, pins):
            cache = Path(root) / "cache"
            cached = F.cached(fetch, cache, lambda name: F.PINS.FILES[name][1])
            F.prepare(Path(root) / "first", fetch=cached)
            F.prepare(Path(root) / "second", fetch=cached)
            self.assertEqual(calls, list(F.NAMES))
            # A corrupted entry is fetched again; a wrong download is refused and not kept.
            (cache / pins[F.NAMES[0]][1]).write_bytes(b"corrupted")
            F.prepare(Path(root) / "third", fetch=cached)
            self.assertEqual(calls, [*F.NAMES, F.NAMES[0]])
            empty = Path(root) / "empty"
            with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
                F.prepare(Path(root) / "fourth", fetch=F.cached(lambda name: b"corrupt", empty,
                                                                 lambda name: F.PINS.FILES[name][1]))
            self.assertFalse(empty.exists())

    def test_corrupt_metadata_refuses(self):
        with tempfile.TemporaryDirectory() as root:
            with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
                F.prepare(Path(root) / "fixture", fetch=lambda name: b"corrupt")

    def test_existing_directory_and_dangling_symlink_refuse(self):
        with tempfile.TemporaryDirectory() as root:
            existing = Path(root) / "existing"
            existing.mkdir()
            link = Path(root) / "link"
            link.symlink_to(Path(root) / "absent")
            for path in (existing, link):
                with self.assertRaises(FileExistsError):
                    F.prepare(path, fetch=lambda name: self.fail("must not download"))

    def test_config_matches_closed_candidate_and_no_weight_pins(self):
        root = Path(__file__).resolve().parent.parent
        candidate = (root / "libs/darkbloom-cluster/Sources/DarkbloomClusterProtocol/ClusterMiMoImageCandidate.swift").read_text()
        self.assertIn(F.PINS.FILES["config.json"][1], candidate)
        self.assertTrue(all(not name.endswith(".safetensors") for name in F.NAMES))
        self.assertLess(sum(F.PINS.FILES[name][0] for name in F.NAMES), 12 * 1024 * 1024)

    body = b"config.json fixture\n"

    def download(self, *outcomes):
        """Runs download() on a synthetic pin against scripted curl outcomes."""
        self.curl = Curl(*outcomes)
        with mock.patch.dict(F.PINS.FILES, {"config.json": (len(self.body), hashlib.sha256(self.body).hexdigest())}), \
                mock.patch.object(F.subprocess, "run", self.curl), mock.patch.object(F.time, "sleep") as sleep:
            self.sleep = sleep
            return F.download("config.json")

    def test_cut_transfers_are_retried_with_backoff(self):
        cases = {
            "partial file": (18, "200", self.body[:4]),
            "TLS EOF": (56, "200", self.body[:4]),
            "connection refused": (7, "000", None),
            "timeout": (28, "200", None),
            "HTTP 503": (0, "503", b"busy"),
            "short body": (0, "200", self.body[:-1]),
            "empty body": (0, "200", None),
        }
        for case, failure in cases.items():
            with self.subTest(case=case):
                self.assertEqual(self.download(failure, (0, "200", self.body)), self.body)
                self.assertEqual(len(self.curl.argv), 2)
                self.sleep.assert_called_once_with(1)
                argv = self.curl.argv[0]
                self.assertNotIn("--fail", argv)
                self.assertNotIn("--location", argv)
                self.assertLessEqual(float(argv[argv.index("--max-time") + 1]), 60)

    def test_three_cut_transfers_fail_after_three_attempts(self):
        with self.assertRaisesRegex(F.TransientTransfer, "curl 18"):
            self.download(*[(18, "200", self.body[:4])] * 3, (0, "200", self.body))
        self.assertEqual(len(self.curl.argv), 3)
        self.assertEqual([call.args for call in self.sleep.call_args_list], [(1,), (3,)])

    def test_integrity_size_status_and_policy_failures_are_not_retried(self):
        cases = {
            "oversize body": ((63, "200", None), subprocess.CalledProcessError),
            "certificate failure": ((60, "000", None), subprocess.CalledProcessError),
            "HTTP 404": ((0, "404", b"missing"), ValueError),
        }
        for case, (failure, error) in cases.items():
            with self.subTest(case=case):
                with self.assertRaises(error):
                    self.download(failure, (0, "200", self.body))
                self.assertEqual(len(self.curl.argv), 1)
                self.sleep.assert_not_called()
        # A full-size body with the wrong digest is returned once and refused by prepare.
        self.assertEqual(self.download((0, "200", b"x" * len(self.body)), (0, "200", self.body)),
                         b"x" * len(self.body))
        self.assertEqual(len(self.curl.argv), 1)
        with tempfile.TemporaryDirectory() as root, self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
            F.prepare(Path(root) / "fixture", fetch=lambda name: b"x" * F.PINS.FILES[name][0])

    def test_a_same_origin_redirect_is_followed(self):
        moved = F.PINS.BASE_URL + "/resolve/config.json"
        self.assertEqual(self.download((0, "302 " + moved, b"moved"), (0, "200", self.body)), self.body)
        self.assertEqual([argv[-1] for argv in self.curl.argv], [F.PINS.BASE_URL + "/config.json", moved])
        self.sleep.assert_not_called()
        # The redirect's body is not the final body: an empty final body is a cut transfer.
        self.assertEqual(self.download((0, "307 " + moved, self.body), (0, "200", None), (0, "200", self.body)),
                         self.body)
        self.assertEqual(len(self.curl.argv), 3)
        self.sleep.assert_called_once_with(1)

    def test_a_redirect_to_another_origin_fails_at_once(self):
        # Each case changes one part of the requested origin.
        requested = urllib.parse.urlsplit(F.PINS.BASE_URL + "/config.json")
        cases = {
            "another HTTPS host": requested._replace(netloc="mirror.example"),
            "another port": requested._replace(netloc=requested.hostname + ":8443"),
            "plain-HTTP downgrade": requested._replace(scheme="http"),
        }
        for case, location in cases.items():
            with self.subTest(case=case):
                with self.assertRaisesRegex(ValueError, "another origin"):
                    self.download((0, "301 " + location.geturl(), None), (0, "200", self.body))
                # The other origin is never requested and nothing is retried.
                self.assertEqual(len(self.curl.argv), 1)
                self.sleep.assert_not_called()

    def test_a_redirect_loop_stops_at_the_limit(self):
        loop = (0, "302 " + F.PINS.BASE_URL + "/config.json", None)
        with self.assertRaisesRegex(ValueError, "redirect limit"):
            self.download(*[loop] * (F.MAX_REDIRECTS + 1), (0, "200", self.body))
        self.assertEqual(len(self.curl.argv), F.MAX_REDIRECTS + 1)
        self.sleep.assert_not_called()

    def test_retries_stay_inside_the_deadline(self):
        # The 1 s backoff would end after the deadline: stop instead of sleeping.
        with mock.patch.object(F, "DEADLINE_SECONDS", 0.5), \
                self.assertRaisesRegex(ValueError, "timed out"):
            self.download((56, "200", None), (0, "200", self.body))
        self.assertEqual(len(self.curl.argv), 1)
        self.sleep.assert_not_called()


if __name__ == "__main__":
    unittest.main()
