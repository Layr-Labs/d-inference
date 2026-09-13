"""Offline fake-transport checks of acceptance assertions; no physical proof."""

from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
import uuid
from unittest.mock import MagicMock, patch

from sandbox_live_evidence import EvidenceCLI, digest
from sandbox_live_expiry import delete_and_expiry
from sandbox_live_files import transfer_recovery
from sandbox_live_http import CHUNK_BYTES, FileAPI, download_chunk, file_denied
from sandbox_live_replay import command_replay
from sandbox_live_suite import LiveSuite


class FileHTTPTests(unittest.TestCase):
    def run_request(self, body, status=200, headers=(), failure=None):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        config = {"environment": "nonproduction", "api_url": "http://127.0.0.1:18080",
                  "allow_insecure_localhost": True, "cli": "/usr/bin/true", "base_image_id": "offline",
                  "host_id": str(uuid.uuid4())}
        client = EvidenceCLI(config, Path(temporary.name) / "evidence", "private-key")
        sandbox_id = str(uuid.uuid4())
        suite = SimpleNamespace(client=client, created=[sandbox_id])
        connection = MagicMock()
        response = connection.getresponse.return_value
        response.status, response.getheaders.return_value, response.read.return_value = status, headers, body
        if failure:
            connection.getresponse.side_effect = failure
        with patch("sandbox_live_http.http.client.HTTPConnection", return_value=connection), \
                patch("sandbox_live_http.threading.Timer") as timer:
            try:
                result = FileAPI(suite).call("offline-probe", sandbox_id, "download", query={"path": "probe.bin"})
            except AssertionError as error:
                result = error
            timer.return_value.cancel.assert_called_once()
        connection.close.assert_called_once()
        return result, client, connection

    def test_exact_request_no_redirect_or_proxy_and_private_bounded_evidence(self):
        result, client, connection = self.run_request(b"private-key", headers=[("Authorization", "private-key"),
            ("X-Sandbox-File-Version", "private-key"), ("Location", "https://outside.invalid")])
        self.assertEqual(result[0], 200)
        self.assertEqual(connection.request.call_count, 1)
        args, kwargs = connection.request.call_args
        self.assertEqual(args[0], "GET")
        self.assertTrue(args[1].startswith("/v1/sandboxes/"))
        self.assertEqual(kwargs["headers"]["Authorization"], "Bearer private-key")
        for path in client.root.iterdir():
            self.assertNotIn(b"private-key", path.read_bytes())
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        record = client.records[-1]
        self.assertNotIn("authorization", record["headers"])
        self.assertTrue(record["response_redacted"])
        self.assertEqual(bytes.fromhex(record["response_hex"]), b"[REDACTED]")

    def test_oversized_and_incomplete_responses_cannot_be_denial_proof(self):
        for body, failure in [(b"x" * (CHUNK_BYTES + 1), None), (b"", OSError("private-key"))]:
            result, client, _ = self.run_request(body, status=409, failure=failure)
            self.assertIsInstance(result, AssertionError)
            self.assertLessEqual(client.records[-1]["response_bytes"], CHUNK_BYTES)
            self.assertTrue(client.records[-1]["failure"])
            self.assertNotIn("private-key", str(result))

    def test_redirect_is_not_followed_or_counted_as_explicit_file_conflict(self):
        result, _, connection = self.run_request(b"", status=302, headers=[("Location", "https://outside.invalid")])
        with self.assertRaises(AssertionError):
            file_denied(result, "file_changed")
        self.assertEqual(connection.request.call_count, 1)

    def test_foreign_sandbox_is_rejected_before_transport(self):
        suite = SimpleNamespace(client=SimpleNamespace(), created=[str(uuid.uuid4())])
        with patch("sandbox_live_http.http.client.HTTPConnection") as connection, self.assertRaises(AssertionError):
            FileAPI(suite).call("foreign", str(uuid.uuid4()), "download")
        connection.assert_not_called()

    def test_raw_guest_operation_or_authority_fields_cannot_be_forwarded(self):
        sandbox_id = str(uuid.uuid4())
        suite = SimpleNamespace(client=SimpleNamespace(), created=[sandbox_id])
        with patch("sandbox_live_http.http.client.HTTPConnection") as connection:
            for operation, body in [("guest_exec", {}), ("begin", {"auth": "injected"})]:
                with self.assertRaises(AssertionError):
                    FileAPI(suite).call("invalid", sandbox_id, operation, body=body)
            connection.assert_not_called()

    def test_hash_revision_and_wrong_denial_are_rejected(self):
        headers = {"content-length": "1", "x-sandbox-file-size": "1", "x-sandbox-file-offset": "0",
                   "x-sandbox-chunk-sha256": digest(b"x"), "x-sandbox-file-version": "a" * 64,
                   "cache-control": "no-store"}
        self.assertEqual(download_chunk((200, headers, b"x"), b"x", 0, 1), "a" * 64)
        for changed in [{"x-sandbox-chunk-sha256": "b" * 64}, {"x-sandbox-file-version": ""}]:
            with self.assertRaises(AssertionError):
                download_chunk((200, dict(headers, **changed), b"x"), b"x", 0, 1)
        with self.assertRaises(AssertionError):
            file_denied((409, {}, b'{"error":{"code":"guest_busy"}}'), "file_changed")


class FileRecoveryTests(unittest.TestCase):
    def test_partial_resume_abort_revision_conflict_and_positive_controls(self):
        self.run_fixture()

    def test_wrong_resume_offset_fails_before_claiming_recovery(self):
        with self.assertRaisesRegex(AssertionError, "offset differs"):
            self.run_fixture(corrupt_offset=True)

    def test_server_ignoring_download_revision_cannot_pass(self):
        with self.assertRaisesRegex(AssertionError, "explicit conflict"):
            self.run_fixture(ignore_version=True)

    def run_fixture(self, **faults):
        with tempfile.TemporaryDirectory() as temporary:
            fake = FakeFiles(Path(temporary), **faults)
            suite = LiveSuite(fake)
            suite.created = suite.sandboxes = [fake.sandbox_id]
            fake.suite = suite
            with patch("sandbox_live_files.FileAPI", return_value=fake), \
                    patch.object(suite, "execute", side_effect=fake.execute):
                transfer_recovery(suite)
            self.assertEqual(fake.resumed_offsets, [CHUNK_BYTES])
            self.assertEqual(fake.stale_denials, 1)
            self.assertEqual(len(fake.files), 1)
            self.assertEqual(list(fake.files.values()), [suite.fixture + b"x"])
            self.assertEqual(sorted(value["state"] for value in fake.transfers.values()), ["aborted", "committed"])


class FakeFiles:
    def __init__(self, root, corrupt_offset=False, ignore_version=False):
        self.root, self.config, self.records = root, {}, []
        self.sandbox_id = str(uuid.uuid4())
        self.transfers, self.files, self.resumed_offsets = {}, {}, []
        self.corrupt_offset, self.ignore_version, self.stale_denials = corrupt_offset, ignore_version, 0

    def write(self, name, value):
        (self.root / name).write_text(json.dumps(value))

    def call(self, label, subject, operation=None, *, transfer_id=None, query=None, body=None, **kwargs):
        if operation is not None:
            assert subject == self.sandbox_id
            if operation == "begin":
                value = dict(body, state="uploading", offset=0)
                self.transfers[body["transfer_id"]] = value
                return 200, {}, json.dumps(value).encode()
            if operation == "chunk":
                assert len(body) == CHUNK_BYTES and query == {"offset": 0}
                value = self.transfers[transfer_id]
                value["offset"] = len(body)
                return 200, {}, json.dumps(value).encode()
            assert operation == "download"
            content = self.files[query["path"]]
            version = digest(content)
            if query.get("version", version) != version and not self.ignore_version:
                self.stale_denials += 1
                return 409, {}, b'{"error":{"code":"file_changed"}}'
            offset = query.get("offset", 0)
            chunk = content[offset:offset + query["length"]]
            return 200, {"content-length": str(len(chunk)), "x-sandbox-file-size": str(len(content)),
                "x-sandbox-file-offset": str(offset), "x-sandbox-chunk-sha256": digest(chunk),
                "x-sandbox-file-version": version, "cache-control": "no-store"}, chunk
        args = subject
        record = {"exit_code": 0, "interrupted": False, "capture_truncated": False}
        def denial(code, status):
            return dict(record, exit_code=1), {"error": f"sandbox request failed: {code} (HTTP {status})"}
        if args[0] == "upload-status":
            value = dict(self.transfers[args[2]])
            if self.corrupt_offset and value["state"] == "uploading":
                value["offset"] = 1
            return record, value
        if args[0] == "upload":
            assert args[1] == "--transfer-id" and args[3] == self.sandbox_id
            value = self.transfers[args[2]]
            self.resumed_offsets.append(value["offset"])
            assert args[5] == value["path"]
            content = Path(args[4]).read_bytes()
            self.files[value["path"]] = content
            value.update(state="committed", offset=len(content))
            return record, dict(value)
        if args[0] == "upload-abort":
            value = self.transfers[args[2]]
            if value["state"] == "committed":
                return denial("upload_already_committed", 409)
            value["state"] = "aborted"
            return record, dict(value)
        if args[0] == "download":
            if args[2] not in self.files:
                return denial("file_not_found", 404)
            content = self.files[args[2]]
            Path(args[3]).write_bytes(content)
            return record, {"size": len(content)}
        raise AssertionError("unexpected fake CLI call")

    def execute(self, sandbox_id, args, **kwargs):
        assert sandbox_id == self.sandbox_id and args[:2] == ["/bin/sh", "-c"]
        path = args[2].removeprefix("printf x >> /workspace/")
        assert path in self.files
        self.files[path] += b"x"
        return {"state": "succeeded", "exit_code": 0}


class ReplayExpiryTests(unittest.TestCase):
    def test_same_key_returns_original_and_effect_is_not_duplicated(self):
        for wrong_id, duplicated in [(False, False), (True, False), (False, True)]:
            with self.subTest(wrong_id=wrong_id, duplicated=duplicated), tempfile.TemporaryDirectory() as temporary:
                sandbox_id, command_id = str(uuid.uuid4()), str(uuid.uuid4())
                client = SimpleNamespace(write=MagicMock(), call=MagicMock(return_value=(
                    {"exit_code": 1, "interrupted": False, "capture_truncated": False},
                    {"error": "sandbox request failed: sandbox_state_conflict (HTTP 409)"})))
                suite = SimpleNamespace(client=client, created=[sandbox_id], sandboxes=[sandbox_id],
                    submit=MagicMock(side_effect=[{"id": command_id}, {"id": str(uuid.uuid4()) if wrong_id else command_id}]),
                    wait_job=MagicMock(return_value={"id": command_id, "state": "succeeded", "stdout": "original\n"}),
                    execute=MagicMock(return_value={"stdout": "once\nonce\n" if duplicated else "once\n"}))
                if wrong_id or duplicated:
                    with self.assertRaises(AssertionError):
                        command_replay(suite)
                else:
                    command_replay(suite)
                    calls = suite.submit.call_args_list
                    self.assertEqual(calls[0].kwargs["key"], calls[1].kwargs["key"])
                    self.assertEqual(client.call.call_args.kwargs["key"], calls[0].kwargs["key"])

    def test_natural_expiry_observes_running_near_deadline_without_stop_or_renew(self):
        suite, proof, elapsed = self.run_expiry()
        self.assertGreaterEqual(elapsed, 1800)
        self.assertEqual(suite.lifecycle.call_args_list[0].args[0], "delete")
        self.assertEqual(suite.lifecycle.call_count, 1)
        self.assertLessEqual(proof["last_running_seconds_before_expiry"], 12)
        self.assertTrue(proof["selected_api_observations_passed"])

    def test_no_running_observation_or_unconfirmed_cleanup_is_a_failure(self):
        for fault in ["never_running", "cleanup_pending", "stopped_early", "expiry_changed"]:
            with self.subTest(fault=fault), self.assertRaises(AssertionError):
                self.run_expiry(fault)

    def run_expiry(self, fault=None):
        elapsed, records = [0.0], []
        expiry = (datetime.now(timezone.utc) + timedelta(seconds=1800)).isoformat()
        a, b, command_id = str(uuid.uuid4()), str(uuid.uuid4()), str(uuid.uuid4())
        client = SimpleNamespace(config={}, write=lambda name, value: records.append(dict(value)))
        def inspect(*args):
            return {"state": "stopped" if fault == "stopped_early" else "ready",
                    "lease_expires_at": expiry + "changed" if fault == "expiry_changed" and elapsed[0] else expiry}
        suite = SimpleNamespace(client=client, created=[a, b], sandboxes=[a, b], lifecycle=MagicMock(),
            inspect=inspect, submit=MagicMock(return_value={"id": command_id}),
            status=MagicMock(return_value={"state": "timed_out" if fault == "never_running" else "running"}),
            wait_job=MagicMock(return_value={"state": "timed_out", "cancellation_pending": fault == "cleanup_pending"}))
        def sleep(seconds):
            elapsed[0] += seconds
        def deleted(*args, **kwargs):
            self.assertEqual(args[:2], (b, "deleted"))
            elapsed[0] = 1801
        suite.wait_state = MagicMock(side_effect=deleted)
        with patch("sandbox_live_expiry.seconds_until", side_effect=lambda _: 1800 - elapsed[0]), \
                patch("sandbox_live_expiry.time.monotonic", side_effect=lambda: elapsed[0]), \
                patch("sandbox_live_expiry.time.sleep", side_effect=sleep), patch("builtins.print"):
            delete_and_expiry(suite)
        self.assertEqual(suite.submit.call_args.kwargs["timeout"], 58)
        return suite, records[-1], elapsed[0]
