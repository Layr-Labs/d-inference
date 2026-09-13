"""Offline account-ownership assertions; no actual API or VM is contacted."""

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import uuid

from sandbox_live_accounts import account_isolation
from sandbox_live_evidence import digest
from sandbox_live_suite import LiveSuite


class AccountIsolationTests(unittest.TestCase):
    def fixture(self, temporary, fault=None):
        network = FakeAccounts(fault)
        primary = AccountClient(Path(temporary), "primary", network)
        secondary = AccountClient(Path(temporary) / "second-account", "secondary", network)
        suite = LiveSuite(primary, secondary)
        first = suite.create("primary-create")
        suite.sandboxes.append(first)
        suite.wait_state(first, "ready")
        return suite, network

    def test_ownership_denials_have_working_controls_and_never_need_three_vms(self):
        with tempfile.TemporaryDirectory() as temporary:
            suite, network = self.fixture(temporary, "uncertain_secondary_create")
            account_isolation(suite)
            suite.create_second()
            self.assertEqual(network.maximum_active, 2)
            self.assertNotIn("second_account_authorization", suite.not_covered)
            record = json.loads((suite.secondary_client.root / "account-isolation.json").read_text())
            self.assertTrue(record["selected_cases_passed"])
            self.assertEqual(record["denied_operations"], ["inspect", "exec", "read_files", "cancel", "delete"])
            second_keys = [key for owner, action, _, key in network.calls if owner == "secondary" and action == "create"]
            self.assertEqual(len(second_keys), 2)
            self.assertEqual(second_keys[0], second_keys[1])
            self.assertEqual(network.sandboxes[record["secondary_sandbox_id"]]["state"], "deleted")
            for owner, action, sandbox_id, _ in network.calls:
                if action == "delete" and sandbox_id == record["secondary_sandbox_id"]:
                    self.assertEqual(owner, "secondary")
            self.assertFalse(any(action == "list" for _, action, _, _ in network.calls))

    def test_unavailable_positive_control_or_successful_foreign_access_cannot_pass(self):
        for fault in ["secondary_exec_fails", "allow_foreign_inspect"]:
            with self.subTest(fault=fault), tempfile.TemporaryDirectory() as temporary:
                suite, network = self.fixture(temporary, fault)
                with self.assertRaises(AssertionError):
                    account_isolation(suite)
                self.assertIn("second_account_authorization", suite.not_covered)
                own = [s for s in network.sandboxes.values() if s["owner"] == "secondary"]
                self.assertTrue(own and all(s["state"] == "deleted" for s in own))
                if fault == "secondary_exec_fails":
                    self.assertFalse(any(owner == "secondary" and sid in suite.created
                                         for owner, _, sid, _ in network.calls))

    def test_uncertain_creation_and_cleanup_failure_preserve_second_account_ledger(self):
        for fault in ["unresolved_secondary_create", "secondary_delete_fails"]:
            with self.subTest(fault=fault), tempfile.TemporaryDirectory() as temporary:
                suite, network = self.fixture(temporary, fault)
                with self.assertRaisesRegex(AssertionError, "cleanup unconfirmed"):
                    account_isolation(suite)
                ledger = json.loads((suite.secondary_client.root / "ownership.json").read_text())
                summary = json.loads((suite.secondary_client.root / "account-isolation.json").read_text())
                self.assertFalse(summary["selected_cases_passed"])
                self.assertTrue(summary["cleanup_failures"])
                self.assertTrue(ledger["pending_creations"] or ledger["created_ids"])
                self.assertFalse(any(owner == "primary" and sid not in suite.created
                                     for owner, action, sid, _ in network.calls if action == "delete"))

    def test_secondary_credential_is_explicit_and_distinct_before_evidence_or_calls(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config = root / "config.json"
            config.write_text("{}")  # Key validation must precede constructing either client.
            for key in ["", "same-private-key"]:
                result = subprocess.run([sys.executable, "-B", str(Path(__file__).with_name("test-sandbox-live.py")),
                    "--config", str(config), "--output", str(root / "evidence"), "--second-account"],
                    env={"DARKBLOOM_API_KEY": "same-private-key", "DARKBLOOM_SECONDARY_API_KEY": key},
                    capture_output=True, timeout=10)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn(b"same-private-key", result.stdout + result.stderr)
                self.assertFalse((root / "evidence").exists())


class AccountClient:
    def __init__(self, root, owner, network):
        self.root, self.owner, self.network = root, owner, network
        self.root.mkdir(exist_ok=True)
        self.config, self.records = {"base_image_id": "offline"}, []

    def write(self, name, value):
        (self.root / name).write_text(json.dumps(value))

    def call(self, label, args, key=None, **kwargs):
        record = {"exit_code": 0, "interrupted": False, "capture_truncated": False,
                  "evidence_file": str(len(self.records)) + ".json"}
        status, value = self.network.call(self, args, key)
        if status != 200:
            record["exit_code"] = 1
            value = {"error": f"sandbox request failed: {value} (HTTP {status})"}
        self.write(record["evidence_file"], {"arguments": args, "idempotency_key": key, "status": status})
        self.records.append(record)
        return record, value


class FakeAccounts:
    def __init__(self, fault):
        self.fault, self.sandboxes, self.creations, self.commands, self.files, self.calls = fault, {}, {}, {}, {}, []
        self.maximum_active = 0

    def call(self, client, args, key):
        owner, action = client.owner, args[0]
        if action == "create":
            ledger = json.loads((client.root / "ownership.json").read_text())
            assert ledger["pending_creations"][key]["arguments"] == args
            ident = self.creations.setdefault((owner, key), str(uuid.uuid4()))
            self.sandboxes.setdefault(ident, {"id": ident, "owner": owner, "state": "ready", "base_image_id": "offline"})
            self.maximum_active = max(self.maximum_active, sum(s["state"] != "deleted" for s in self.sandboxes.values()))
            self.calls.append((owner, action, ident, key))
            if owner == "secondary" and (self.fault == "unresolved_secondary_create" or self.fault == "uncertain_secondary_create" and
                    sum(o == owner and a == action for o, a, _, _ in self.calls) == 1):
                return 503, "outcome_uncertain"
            return 200, {"sandbox": dict(self.sandboxes[ident])}
        ident = args[args.index("--") - 1] if action == "exec" else args[3] if action == "upload" else args[2] if action == "job" else args[-1] if action in {"start", "delete"} else args[1]
        self.calls.append((owner, action, ident, key))
        sandbox = self.sandboxes[ident]
        if sandbox["owner"] != owner and not (self.fault == "allow_foreign_inspect" and action == "inspect"):
            return 404, "sandbox_not_found"
        if action == "inspect":
            return 200, dict(sandbox)
        if action == "delete":
            if owner == "secondary" and self.fault == "secondary_delete_fails":
                return 503, "cleanup_unavailable"
            sandbox["state"] = "deleted"
            return 200, {"operation": {"state": "deleted"}}
        if action == "start":
            sandbox["state"] = "ready"
            return 200, {"operation": {"state": "ready"}}
        if action == "upload":
            content = Path(args[4]).read_bytes()
            self.files[(ident, args[5])] = content
            return 200, {"state": "committed", "size": len(content), "sha256": digest(content)}
        if action == "download":
            content = self.files[(ident, args[2])]
            Path(args[3]).write_bytes(content)
            return 200, {"size": len(content)}
        if action == "exec":
            if owner == "secondary" and self.fault == "secondary_exec_fails":
                return 503, "host_unavailable"
            arguments = args[args.index("--") + 1:]
            command_id = str(uuid.uuid4())
            running = arguments[0] == "/bin/sleep"
            output = arguments[1] if arguments[0] == "/usr/bin/printf" else "primary-owner\n" if arguments[0] == "/bin/sh" else ""
            command = {"id": command_id, "sandbox_id": ident, "state": "running" if running else "succeeded",
                       "stdout": output, "exit_code": 0, "cancellation_pending": False}
            self.commands[command_id] = [command, 0]
            return 200, dict(command)
        if action == "job":
            command, count = self.commands[args[3]]
            if args[1] == "cancel":
                command["state"], sandbox["state"] = "cancelled", "stopped"
            elif command["state"] == "running" and count:
                command["state"] = "succeeded"
            self.commands[args[3]][1] += 1
            return 200, dict(command)
        raise AssertionError("unexpected offline account operation")
