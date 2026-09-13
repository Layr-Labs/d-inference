#!/usr/bin/env python3
"""Offline tests for the acceptance harness; never contact a coordinator."""

import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
import uuid
from unittest.mock import patch

from sandbox_live_evidence import EvidenceCLI, MAX_CAPTURE, denied, validate_config
from sandbox_live_suite import LiveSuite
from sandbox_live_quota import workspace_exhaustion
from sandbox_live_cases_tests import FileHTTPTests, FileRecoveryTests, ReplayExpiryTests
from sandbox_live_accounts_tests import AccountIsolationTests


def configuration(cli):
    return {"environment": "nonproduction", "api_url": "http://127.0.0.1:18080",
            "allow_insecure_localhost": True, "cli": str(cli), "base_image_id": "test-base-v1",
            "host_id": "31dbb7e8-3332-4dc3-b882-5a9c5c6b0fb0"}


class HarnessTests(unittest.TestCase):
    def fake_cli(self, directory, body):
        path = Path(directory) / "fake-cli"
        path.write_text("#!" + sys.executable + "\n" + body)
        path.chmod(0o755)
        return path

    def test_explicit_nonproduction_origin_and_credential_free_config(self):
        with tempfile.TemporaryDirectory() as temporary:
            cli = self.fake_cli(temporary, "pass\n")
            self.assertEqual(validate_config(configuration(cli))["environment"], "nonproduction")
            for changes in [{"environment": "production"}, {"api_url": "https://api.darkbloom.dev"},
                            {"api_url": "https://api.darkbloom.dev./"}, {"api_url": "https://user:secret@example.test"},
                            {"api_url": "http://example.test"}, {"api_key": "secret"}]:
                with self.subTest(changes=changes), self.assertRaises(AssertionError):
                    validate_config(dict(configuration(cli), **changes))

    def test_cli_evidence_hashes_raw_output_and_excludes_api_key(self):
        with tempfile.TemporaryDirectory() as temporary:
            cli = self.fake_cli(temporary, "import json, os\nassert os.environ['DARKBLOOM_API_KEY'] == 'private-key'\nassert 'DARKBLOOM_SECONDARY_API_KEY' not in os.environ\nassert 'EIGENINFERENCE_DATABASE_URL' not in os.environ\nprint(json.dumps({'ok':True}))\n")
            client = EvidenceCLI(configuration(cli), Path(temporary) / "evidence", "private-key")
            with patch.dict(os.environ, {"DARKBLOOM_SECONDARY_API_KEY": "other-private-key", "EIGENINFERENCE_DATABASE_URL": "private-db"}):
                record, payload = client.call("probe", ["help"])
            self.assertEqual(payload, {"ok": True})
            self.assertEqual(record["exit_code"], 0)
            self.assertEqual(len(record["stdout"]["sha256"]), 64)
            for path in client.root.iterdir():
                self.assertNotIn(b"private-key", path.read_bytes())
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            with self.assertRaises(FileExistsError):
                EvidenceCLI(configuration(cli), client.root, "private-key")

    def test_cli_capture_is_bounded_and_marks_truncation(self):
        with tempfile.TemporaryDirectory() as temporary:
            cli = self.fake_cli(temporary, "import os\nos.write(1, b'x' * (9 * 1024 * 1024))\n")
            client = EvidenceCLI(configuration(cli), Path(temporary) / "evidence", "private-key")
            record, payload = client.call("oversize", ["help"])
            self.assertTrue(record["capture_truncated"])
            self.assertEqual(record["stdout"]["bytes"], MAX_CAPTURE)
            self.assertIsNone(payload)

    def test_cli_timeout_retains_evidence_and_is_not_success(self):
        with tempfile.TemporaryDirectory() as temporary:
            cli = self.fake_cli(temporary, "import time\nprint('started', flush=True)\ntime.sleep(20)\n")
            client = EvidenceCLI(configuration(cli), Path(temporary) / "evidence", "private-key")
            record, _ = client.call("timeout", ["help"], timeout=1)
            self.assertTrue(record["interrupted"])
            self.assertNotEqual(record["exit_code"], 0)
            self.assertIn(b"started", (client.root / record["stdout"]["path"]).read_bytes())

    def test_transport_failure_cannot_count_as_cross_instance_denial(self):
        record = {"exit_code": 1, "interrupted": False, "capture_truncated": False}
        denied((record, {"error": "sandbox request failed: transfer_not_found (HTTP 404)"}), "transfer_not_found")
        for result in [(record, {"error": "sandbox request could not complete; its outcome may be uncertain"}),
                       (dict(record, interrupted=True), {"error": "sandbox request failed: transfer_not_found (HTTP 404)"}),
                       (record, {"error": "sandbox request failed: file_not_found (HTTP 404)"})]:
            with self.assertRaises(AssertionError):
                denied(result, "transfer_not_found")

    def test_uncertain_create_retries_same_key_and_cleanup_only_created_id(self):
        with tempfile.TemporaryDirectory() as temporary:
            client = FakeClient(Path(temporary))
            suite = LiveSuite(client)
            created = suite.create("create-a")
            self.assertEqual(created, client.owned_id)
            self.assertEqual(client.calls[0][2], client.calls[1][2])
            self.assertEqual(suite.pending, {})
            self.assertEqual(suite.cleanup(), [])
            self.assertTrue(all(client.foreign_id not in call[1] for call in client.calls))
            self.assertFalse(any(call[1][0] == "list" for call in client.calls))
            self.assertEqual(json.loads((client.root / "cleanup.json").read_text())["created_ids"], [client.owned_id])

    def test_definite_rejected_create_is_not_reissued_during_cleanup(self):
        with tempfile.TemporaryDirectory() as temporary:
            client = FakeClient(Path(temporary), reject=True)
            suite = LiveSuite(client)
            with self.assertRaises(AssertionError):
                suite.create("create-a")
            self.assertEqual(suite.pending, {})
            self.assertEqual(suite.cleanup(), [])
            self.assertEqual(len(client.calls), 1)

    def test_cleanup_failure_is_retained_and_never_claimed_deleted(self):
        with tempfile.TemporaryDirectory() as temporary:
            client = FakeClient(Path(temporary))
            suite = LiveSuite(client)
            suite.created = [client.owned_id]
            with patch.object(suite, "inspect", side_effect=AssertionError("unavailable")):
                failures = suite.cleanup()
            self.assertEqual(failures, ["deletion unconfirmed for " + client.owned_id])

    def test_combined_output_allows_envelope_budget_but_requires_both_streams(self):
        with tempfile.TemporaryDirectory() as temporary:
            suite = LiveSuite(FakeClient(Path(temporary)))
            suite.sandboxes = [suite.client.owned_id]
            separate = [{"stdout": "O" * 1048576, "output_truncated": True},
                        {"stderr": "E" * 1048576, "output_truncated": True}]
            for length in [1048000, 0]:
                combined = {"stdout": "O" * length, "stderr": "E" * length, "output_truncated": True}
                with patch.object(suite, "execute", side_effect=separate + [combined]):
                    if length:
                        suite.bounded_output()
                    else:
                        with self.assertRaises(AssertionError):
                            suite.bounded_output()

    def test_cancel_recovery_waits_for_authoritative_stop_before_start(self):
        with tempfile.TemporaryDirectory() as temporary:
            suite = LiveSuite(FakeClient(Path(temporary)))
            events = []
            def stopped(*args, **kwargs):
                events.append("observed-stopped")
                return {"state": "stopped"}
            with patch.object(suite, "inspect", side_effect=AssertionError("stale-ready must not be used")), \
                    patch.object(suite, "wait_state", side_effect=stopped), \
                    patch.object(suite, "lifecycle", side_effect=lambda *a: events.append("start")), \
                    patch.object(suite, "execute", side_effect=lambda *a: events.append("exec") or {"stdout": "recovered\n"}):
                suite.recovered(suite.client.owned_id, expect_vm_stop=True)
            self.assertEqual(events, ["observed-stopped", "start", "exec"])

    def test_workspace_exhaustion_is_opt_in_and_excludes_foreign_paths(self):
        with tempfile.TemporaryDirectory() as temporary:
            suite = LiveSuite(FakeClient(Path(temporary)))
            self.assertIn("workspace_exhaustion", suite.not_covered)
            self.assertIn("physical_host_inventory_and_storage_removal", suite.not_covered)
            self.assertIn("second_account_authorization", suite.not_covered)
            suite.sandboxes = [suite.client.foreign_id]
            with self.assertRaisesRegex(AssertionError, "created by this run"):
                workspace_exhaustion(suite)

    def test_summary_names_selection_and_unverified_physical_gates_after_failure(self):
        with tempfile.TemporaryDirectory() as temporary:
            suite = LiveSuite(FakeClient(Path(temporary)))
            with patch.object(suite, "create_first", side_effect=AssertionError("offline fixture failure")), \
                    patch.object(suite, "cleanup", return_value=[]):
                self.assertFalse(suite.run())
            summary = json.loads((suite.client.root / "summary.json").read_text())
            self.assertFalse(summary["passed"])
            self.assertFalse(summary["production_ready"])
            self.assertIn("selected consumer API", summary["evidence_scope"])
            self.assertIn("broker_crash_restart_and_host_reboot_reconciliation", summary["not_covered"])
            self.assertTrue(all(case["status"] == "blocked" for case in summary["cases"][1:]))

    def test_workspace_enospc_is_bounded_and_recovers_after_removing_only_its_file(self):
        self.run_quota_fixture("No space left on device", succeeds=True)

    def test_other_disk_error_is_not_quota_proof_but_still_removes_owned_file(self):
        self.run_quota_fixture("Input/output error", succeeds=False)

    def run_quota_fixture(self, disk_error, succeeds):
        with tempfile.TemporaryDirectory() as temporary:
            suite = LiveSuite(FakeClient(Path(temporary)))
            suite.created = suite.sandboxes = [suite.client.owned_id]
            invocations = []
            def execute(sandbox_id, args, **kwargs):
                invocations.append((sandbox_id, args, kwargs))
                if args[0] == "/bin/dd":
                    return {"exit_code": 1, "stderr": disk_error}
                if args[0] == "/usr/bin/id":
                    return {"stdout": "2001\n"}
                return {"exit_code": 0}
            record = {"exit_code": 0, "interrupted": False, "capture_truncated": False}
            from sandbox_live_evidence import digest
            uploaded = {"state": "committed", "sha256": digest(suite.fixture)}
            with patch.object(suite, "execute", side_effect=execute), patch.object(suite, "recovered"), \
                    patch.object(suite, "download_exact") as downloaded, \
                    patch.object(suite.client, "call", return_value=(record, uploaded)) as client_call:
                if succeeds:
                    workspace_exhaustion(suite)
                    downloaded.assert_called_once()
                    client_call.assert_called_once()
                else:
                    with self.assertRaisesRegex(AssertionError, "ENOSPC"):
                        workspace_exhaustion(suite)
                    client_call.assert_not_called()
            dd = invocations[0]
            self.assertEqual(dd[2]["timeout"], 900)
            self.assertIn("count=26624", dd[1])
            path = next(arg[3:] for arg in dd[1] if arg.startswith("of="))
            self.assertTrue(path.startswith("/workspace/quota-"))
            removals = [args for _, args, _ in invocations if args[0] == "/bin/rm"]
            self.assertEqual(removals, [["/bin/rm", "-f", "--", path]])
            self.assertTrue(all(sandbox_id == suite.client.owned_id for sandbox_id, _, _ in invocations))


class FakeClient:
    def __init__(self, root, reject=False):
        self.root, self.reject = root, reject
        self.config = {"base_image_id": "test-base-v1"}
        self.records, self.calls = [], []
        self.owned_id, self.foreign_id = str(uuid.uuid4()), str(uuid.uuid4())
        self.state = "ready"

    def write(self, name, payload):
        (self.root / name).write_text(json.dumps(payload))

    def call(self, label, args, key=None, **kwargs):
        self.calls.append((label, args, key))
        record = {"exit_code": 0, "interrupted": False, "capture_truncated": False}
        if args[0] == "create":
            ledger = json.loads((self.root / "ownership.json").read_text())
            if ledger["pending_creations"][key]["arguments"] != args:
                raise AssertionError("create was sent before its ownership intent was saved")
            if self.reject:
                record["exit_code"] = 1
                return record, {"error": "sandbox request failed: capacity (HTTP 429)"}
            if len(self.calls) == 1:
                record["exit_code"] = 1
                return record, {"error": "sandbox request could not complete; its outcome may be uncertain"}
            return record, {"sandbox": {"id": self.owned_id, "base_image_id": "test-base-v1"}}
        if args[0] == "inspect":
            return record, {"id": self.owned_id, "state": self.state}
        if args[0] == "delete":
            self.state = "deleted"
            return record, {"operation": {"state": "deleting"}}
        raise AssertionError("unexpected fake CLI call")


if __name__ == "__main__":
    print("Offline harness assertions: fake CLI/REST transports and simulated time; no physical acceptance.", flush=True)
    unittest.main()
