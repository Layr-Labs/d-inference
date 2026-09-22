"""Run release input handling against local fixtures, without signing or publishing."""

import base64
from datetime import datetime, timedelta, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent


def release_step(name):
    workflow = (ROOT / ".github/workflows/release-swift.yml").read_text()
    step = workflow.split("      - name: " + name + "\n", 1)[1]
    script = step.split("        run: |\n", 1)[1]
    lines = []
    for line in script.splitlines():
        if line and not line.startswith("          "):
            break
        lines.append(line[10:])
    return "\n".join(lines) + "\n"


class ReleaseWorkflowTests(unittest.TestCase):
    def test_profile_validation_authorizes_this_app_before_embedding(self):
        for scenario in ("valid", "wrong-long-app", "wrong-short-team", "unrelated-wildcard",
                         "missing-expiry", "short-expiry", "development-push"):
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                app = "SLDQ2GJ6TL.io.darkbloom.provider"
                profile = {
                    "TeamIdentifier": ["SLDQ2GJ6TL"],
                    "ExpirationDate": datetime.now(timezone.utc).replace(tzinfo=None) + timedelta(days=60),
                    "Entitlements": {"keychain-access-groups": [app], "aps-environment": "production"},
                }
                entitlements = profile["Entitlements"]
                if scenario == "wrong-long-app":
                    entitlements["com.apple.application-identifier"] = "SLDQ2GJ6TL.other"
                if scenario == "wrong-short-team":
                    entitlements["application-identifier"] = "OTHERTEAM.io.darkbloom.provider"
                if scenario == "unrelated-wildcard":
                    entitlements["application-identifier"] = "SLDQ2GJ6TL.unrelated.*"
                if scenario == "missing-expiry":
                    profile.pop("ExpirationDate")
                if scenario == "short-expiry":
                    profile["ExpirationDate"] = datetime.now(timezone.utc).replace(tzinfo=None) + timedelta(days=2)
                if scenario == "development-push":
                    entitlements["aps-environment"] = "development"
                fixture = root / "fixture.plist"
                fixture.write_bytes(plistlib.dumps(profile))
                security = root / "security"
                security.write_text('#!/bin/sh\nexec cat "$RELEASE_PROFILE_FIXTURE"\n')
                security.chmod(0o755)
                # Redirect the old workflow's fixed /tmp paths into this fixture
                # too, so the regression can run safely against its baseline.
                script = release_step("Embed provisioning profile").replace("/tmp/", directory + "/")
                result = subprocess.run(["bash", "-c", script], cwd=ROOT,
                    env={**os.environ, "PATH": directory + os.pathsep + os.environ["PATH"],
                         "RUNNER_TEMP": directory, "GITHUB_OUTPUT": str(root / "outputs"),
                         "PROVISIONING_PROFILE_BASE64": base64.b64encode(b"fixture CMS").decode(),
                         "RELEASE_PROFILE_FIXTURE": str(fixture)},
                    capture_output=True, text=True, timeout=10)
                if scenario == "valid":
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn("profile_available=true", (root / "outputs").read_text())
                else:
                    self.assertNotEqual(result.returncode, 0, result.stdout)
                    self.assertFalse((root / "outputs").exists())

    def test_release_payload_preserves_tag_text_as_json_data(self):
        step = release_step("Prepare signed release qualification evidence")
        for message in ('Ordinary release', 'Quotes: """; backslash: \\n; literal: $HOME\nSecond line\tend'):
            with self.subTest(message=message), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                bundle = root / "darkbloom-bundle-macos-arm64.tar.gz"
                bundle.write_bytes(b"retained signed fixture")
                digest = hashlib.sha256(bundle.read_bytes()).hexdigest()
                git = root / "git"
                git.write_text('#!/bin/sh\nprintf \'%s\\n\' "$TAG_MSG"\n')
                git.chmod(0o755)
                result = subprocess.run(["bash", "-euc", step.replace("/tmp/", directory + "/")], cwd=ROOT,
                    env={**os.environ, "PATH": directory + os.pathsep + os.environ["PATH"],
                         "RUNNER_TEMP": directory, "GITHUB_OUTPUT": str(root / "outputs"),
                         "GITHUB_STEP_SUMMARY": str(root / "summary"), "GITHUB_RUN_ATTEMPT": "1",
                         "VERSION": "0.9.7", "TAG_MSG": message, "ENV_PREFIX": "prod",
                         "GITHUB_REF_TYPE": "tag", "GITHUB_REF_NAME": "v0.9.7",
                         "GITHUB_SHA": "d" * 40, "GITHUB_RUN_ID": "123",
                         "GITHUB_REPOSITORY": "fixture/repository",
                         "R2_PUBLIC_URL": "https://example.invalid", "COORDINATOR_URL": "https://coordinator.invalid",
                         "BINARY_HASH": "a" * 64, "BUNDLE_HASH": digest,
                         "METALLIB_HASH": "b" * 64, "CODE_DIRECTORY_HASH": "c" * 64},
                    capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
                payload = json.loads((root / "provider-publication/release-payload.json").read_text())
                self.assertEqual(payload, {"version": "0.9.7", "platform": "macos-arm64",
                    "backend": "mlx-swift", "binary_hash": "a" * 64, "bundle_hash": digest,
                    "metallib_hash": "b" * 64, "code_directory_hash": "c" * 64,
                    "source_commit": "d" * 40, "ci_run_id": "123",
                    "require_app_attest_qualification": True,
                    "url": f"https://example.invalid/releases/v0.9.7/artifacts/{digest}/{bundle.name}",
                    "changelog": message})
                qualification = json.loads((root / "provider-publication/qualification-request.json").read_text())
                self.assertEqual(qualification["release"]["changelog"], message)
                self.assertEqual(qualification["evidence"], "")



if __name__ == "__main__":
    unittest.main()
