"""Exercise publishing preflight and failure cleanup with offline command stubs."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
STUB = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

tool, args = Path(sys.argv[0]).name, sys.argv[1:]
root = Path(os.environ["PUBLISH_FIXTURE_ROOT"])
event = {"tool": tool, "args": args}
if tool == "aws":
    event["credentials"] = [os.environ.get(key) for key in
                            ("AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY")]
if tool == "curl":
    data = args[args.index("--data") + 1]
    event["payload"] = json.loads(Path(data[1:]).read_text() if data.startswith("@") else data)
with (root / "events.jsonl").open("a") as stream:
    stream.write(json.dumps(event) + "\n")
if tool == "gcloud":
    secret = args[args.index("--secret") + 1]
    if secret == os.environ.get("PUBLISH_FIXTURE_FAILED_SECRET"):
        print("fixture secret lookup failed", file=sys.stderr)
        raise SystemExit(7)
    if secret != os.environ.get("PUBLISH_FIXTURE_EMPTY_SECRET"):
        print("verified-" + secret)
elif tool == "swift":
    Path(args[args.index("-o") + 1]).write_text(json.dumps({
        "r2_prefix": "v2/published/v1", "files": [{"path": "weights.safetensors"}]
    }))
elif tool == "aws":
    if os.environ.get("PUBLISH_FIXTURE_FAIL_TOOL") == tool:
        raise SystemExit(8)
    if args[:2] == ["s3", "cp"] and not args[3].startswith("s3://"):
        Path(args[3]).write_text(json.dumps({
            "model_id": "source/model", "version": "v1", "r2_prefix": "old-prefix",
            "files": [{"path": "weights.safetensors", "sha256": "unchanged"}]
        }))
elif tool == "curl":
    if os.environ.get("PUBLISH_FIXTURE_FAIL_TOOL") == tool:
        raise SystemExit(9)
    print("{}")
'''


class ModelPublishingTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.staging = self.root / "staging"
        self.staging.mkdir()
        self.model = self.root / "model"
        self.model.mkdir()
        (self.model / "weights.safetensors").write_bytes(b"fixture")
        for tool in ("swift", "gcloud", "aws", "curl"):
            path = self.bin / tool
            path.write_text(STUB)
            path.chmod(0o755)
        self.env = {**os.environ, "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
                    "PUBLISH_FIXTURE_ROOT": str(self.root), "TMPDIR": str(self.staging),
                    "GCP_PROJECT": "fixture", "R2_ACCOUNT_ID": "fixture",
                    "R2_ACCESS_KEY_SECRET": "access-id", "R2_SECRET_KEY_SECRET": "secret-key",
                    "R2_BUCKET": "fixture-models", "HUGGING_FACE_ARTIFACT_JSON": "null",
                    "AWS_ACCESS_KEY_ID": "stale-access", "AWS_SECRET_ACCESS_KEY": "stale-secret"}

    def events(self):
        path = self.root / "events.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def invoke(self, lane, *, env=None, fields=None):
        if lane == "publish":
            args = ["bash", str(ROOT / "scripts/publish-model.sh")]
            data = f"{self.model}\npublished-model\nv1\n\n"
        else:
            values = ["source/model", "v1", "rollback/model", "https://coordinator.invalid",
                      "fixture-key", "4bit", "16", "8192", "1024", "10", "20", "chat,tools"]
            for index, value in (fields or {}).items():
                values[index] = value
            args = ["bash", str(ROOT / "scripts/preposition-rollback-build.sh"), *values]
            data = None
        return subprocess.run(args, input=data, text=True, errors="replace", capture_output=True,
                              env={**self.env, **(env or {})}, timeout=20)

    def reset(self):
        (self.root / "events.jsonl").unlink(missing_ok=True)

    def test_secret_failure_stops_both_publishers_before_any_remote_write(self):
        for lane in ("publish", "rollback"):
            for secret in ("access-id", "secret-key"):
                with self.subTest(lane=lane, secret=secret):
                    self.reset()
                    result = self.invoke(lane, env={"PUBLISH_FIXTURE_FAILED_SECRET": secret})
                    self.assertNotEqual(result.returncode, 0, result.stdout)
                    self.assertFalse(any(e["tool"] in ("aws", "curl") for e in self.events()))
                    self.assertEqual(list(self.staging.iterdir()), [])

    def test_empty_secrets_stop_both_publishers_before_any_remote_write(self):
        for lane in ("publish", "rollback"):
            for secret in ("access-id", "secret-key"):
                with self.subTest(lane=lane, secret=secret):
                    self.reset()
                    result = self.invoke(lane, env={"PUBLISH_FIXTURE_EMPTY_SECRET": secret})
                    self.assertNotEqual(result.returncode, 0, result.stdout)
                    self.assertFalse(any(e["tool"] in ("aws", "curl") for e in self.events()))
                    self.assertEqual(list(self.staging.iterdir()), [])

    def test_invalid_registry_numbers_fail_before_credential_lookup_or_copy(self):
        for index in range(6, 11):
            for value in ("not-an-integer", "0", "-1", str(2**63)):
                with self.subTest(index=index, value=value):
                    self.reset()
                    result = self.invoke("rollback", fields={index: value})
                    self.assertNotEqual(result.returncode, 0, result.stdout)
                    self.assertEqual(self.events(), [])
                    self.assertEqual(list(self.staging.iterdir()), [])

    def test_rollback_identifiers_and_distinct_destination_are_preflighted(self):
        for fields in ({0: "../bad"}, {1: "bad/version"}, {1: 'bad"version'},
                       {2: "/bad"}, {2: "bad%2fmodel"}, {2: "source/model"}, {5: " "}):
            with self.subTest(fields=fields):
                self.reset()
                result = self.invoke("rollback", fields=fields)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertEqual(self.events(), [])
                self.assertEqual(list(self.staging.iterdir()), [])

    def test_success_keeps_verified_credentials_upload_order_and_registration(self):
        for lane in ("publish", "rollback"):
            with self.subTest(lane=lane):
                self.reset()
                result = self.invoke(lane)
                self.assertEqual(result.returncode, 0, result.stderr)
                events = self.events()
                uploads = [e for e in events if e["tool"] == "aws"]
                self.assertTrue(uploads)
                for event in uploads:
                    self.assertEqual(event["credentials"], ["verified-access-id", "verified-secret-key"])
                if lane == "publish":
                    self.assertTrue(uploads[-1]["args"][3].endswith("/manifest.json"))
                    self.assertFalse(any(e["tool"] == "curl" for e in events))
                else:
                    calls = [e for e in events if e["tool"] == "curl"]
                    self.assertEqual(len(calls), 2)
                    registration = calls[0]["payload"]
                    self.assertEqual(registration["model_id"], "rollback/model")
                    self.assertEqual(registration["capabilities"], ["chat", "tools"])
                    self.assertEqual(registration["input_price"], 10)
                    self.assertEqual(calls[1]["payload"], {"version": "v1"})
                    self.assertLess(events.index(uploads[-1]), events.index(calls[0]))
                self.assertEqual(list(self.staging.iterdir()), [])

    def test_failed_copy_or_registration_cleans_owned_staging_and_stops(self):
        for tool in ("aws", "curl"):
            with self.subTest(tool=tool):
                self.reset()
                result = self.invoke("rollback", env={"PUBLISH_FIXTURE_FAIL_TOOL": tool})
                self.assertNotEqual(result.returncode, 0)
                calls = [e for e in self.events() if e["tool"] == "curl"]
                self.assertEqual(len(calls), 0 if tool == "aws" else 1)
                self.assertEqual(list(self.staging.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
