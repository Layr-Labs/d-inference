"""Run release input handling against local fixtures, without signing or publishing."""

import base64
from datetime import datetime, timedelta, timezone
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
        step = release_step("Register release with coordinator")
        phase = step[step.index("python3 - <<"):step.index("curl -fsSL -X POST")]
        for message in ('Ordinary release', 'Quotes: """; backslash: \\n; literal: $HOME\nSecond line\tend'):
            with self.subTest(message=message), tempfile.TemporaryDirectory() as directory:
                script = phase.replace("/tmp/", directory + "/")
                result = subprocess.run(["bash", "-euc", script], cwd=ROOT,
                    env={**os.environ, "VERSION": "fixture-version", "TAG_MSG": message,
                         "BUNDLE_URL": "https://example.invalid/bundle", "BINARY_HASH": "binary",
                         "BUNDLE_HASH": "bundle", "METALLIB_HASH": "metallib"},
                    capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
                payload = json.loads((Path(directory) / "release-payload.json").read_text())
                self.assertEqual(payload, {"version": "fixture-version", "platform": "macos-arm64",
                    "backend": "mlx-swift", "binary_hash": "binary", "bundle_hash": "bundle",
                    "metallib_hash": "metallib", "url": "https://example.invalid/bundle",
                    "changelog": message})


if __name__ == "__main__":
    unittest.main()
