"""Exercise the boot env phase with local metadata and Secret Manager stubs."""

import os
import re
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
DEPLOY = ROOT / "deploy/gcp"


class DevEnvironmentTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.env_dir = self.root / "env"
        self.env_dir.mkdir()
        self.env_file = self.env_dir / "env"
        self.scratch = self.root / "scratch"
        self.scratch.mkdir()
        self.env = {
            **os.environ,
            "PATH": f"{self.bin}:{os.environ['PATH']}",
            "ENV_DIR": str(self.env_dir),
            "TMPDIR": str(self.scratch),
            "REFRESH_SCRIPT": str(DEPLOY / "refresh-env.sh"),
            "MISSING_SECRET": "",
            "METADATA_FAIL": "0",
        }
        self.stub("gcloud", '''#!/bin/bash
set -eu
for arg; do
  case "$arg" in
    --secret=*) secret=${arg#--secret=} ;;
  esac
done
[ "$secret" != "$MISSING_SECRET" ] || exit 1
printf 'fixture-%s' "$secret"
''')
        self.stub("curl", '''#!/bin/bash
set -eu
while [ "$#" -gt 0 ]; do
  if [ "$1" = -o ]; then out=$2; break; fi
  shift
done
[ "$METADATA_FAIL" = 0 ] || exit 22
cp "$REFRESH_SCRIPT" "$out"
''')

    def stub(self, name, content):
        path = self.bin / name
        path.write_text(content)
        path.chmod(0o755)

    def run_phase(self, boot):
        if boot:
            # Execute the actual env phase, excluding package installation,
            # disk formatting, systemd, and all other host mutations.
            startup = (DEPLOY / "vm-startup.sh").read_text()
            phase = startup.split("# ---- 3.", 1)[1].split("# ---- 4.", 1)[0]
            phase = phase.split("\n", 1)[1]
            command = ["bash", "-euc", 'ENV_FILE="$ENV_DIR/env"\n' + phase]
        else:
            command = ["bash", str(DEPLOY / "refresh-env.sh")]
        return subprocess.run(command, env=self.env, text=True, capture_output=True)

    def assert_clean(self):
        self.assertEqual(list(self.scratch.iterdir()), [])
        self.assertEqual(list(self.env_dir.iterdir()), [self.env_file])

    def test_bootstrap_resources_can_be_populated_before_boot_retry(self):
        resources = self.root / "secrets"
        resources.mkdir()
        self.env["FIXTURE_SECRETS"] = str(resources)
        self.stub("gcloud", '''#!/usr/bin/env python3
import os
from pathlib import Path
import sys
args = [arg for arg in sys.argv[1:] if arg != "--quiet"]
root = Path(os.environ["FIXTURE_SECRETS"])
if args[:2] == ["secrets", "describe"]:
    sys.exit(0 if (root / args[2]).exists() else 1)
if args[:2] == ["secrets", "create"]:
    (root / args[2]).touch(exist_ok=False)
elif args[:3] == ["secrets", "versions", "add"]:
    target = root / args[3]
    if not target.exists():
        sys.exit(1)
    target.write_text(sys.stdin.read())
elif args[:3] == ["secrets", "versions", "access"]:
    name = next(arg.split("=", 1)[1] for arg in args if arg.startswith("--secret="))
    target = root / name
    if not target.exists() or not target.read_text():
        sys.exit(1)
    print(target.read_text(), end="")
else:
    raise SystemExit("unexpected fixture gcloud invocation: " + repr(args))
''')
        # Run the real resource-creation phase, excluding cloud provisioning,
        # IAM, credentials and VM creation. Every transport call stays local.
        source = (DEPLOY / "bootstrap.sh").read_text()
        phase = source.split('echo "==> Creating Secret Manager entries"', 1)[1]
        phase = phase.split('echo "==> Grant coord SA decrypt', 1)[0]
        command = ["bash", "-euc", phase]
        env = {**self.env, "PROJECT": "fixture", "REGION": "fixture",
               "KMS_RING": "fixture", "KMS_KEY_MDM": "mdm", "KMS_KEY_SOLANA": "mnemonic"}
        created = subprocess.run(command, env=env, text=True, capture_output=True)
        self.assertEqual(created.returncode, 0, created.stderr)
        expected = set(re.findall(r"\$\(fetch ([a-z0-9-]+)\)",
                                  (DEPLOY / "refresh-env.sh").read_text()))
        self.assertLessEqual(expected, {path.name for path in resources.iterdir()})
        self.assertNotEqual(self.run_phase(boot=True).returncode, 0)
        self.assertFalse(self.env_file.exists())
        for name in expected:
            populated = subprocess.run(
                ["gcloud", "secrets", "versions", "add", name, "--data-file=-"],
                env=self.env, input="fixture-" + name, text=True, capture_output=True,
            )
            self.assertEqual(populated.returncode, 0, populated.stderr)
        before = {path.name: path.read_bytes() for path in resources.iterdir()}
        repeated = subprocess.run(command, env=env, text=True, capture_output=True)
        self.assertEqual(repeated.returncode, 0, repeated.stderr)
        self.assertEqual(before, {path.name: path.read_bytes() for path in resources.iterdir()})
        boot = self.run_phase(boot=True)
        self.assertEqual(boot.returncode, 0, boot.stdout + boot.stderr)
        self.assertIn("EIGENINFERENCE_STRIPE_CONNECT_WEBHOOK_SECRET=fixture-", self.env_file.read_text())
        self.assert_clean()

    def test_boot_and_deploy_publish_identical_complete_environment(self):
        deploy = self.run_phase(boot=False)
        self.assertEqual(deploy.returncode, 0, deploy.stderr)
        expected = self.env_file.read_bytes()
        self.env_file.write_text("old-environment\n")
        boot = self.run_phase(boot=True)
        self.assertEqual(boot.returncode, 0, boot.stderr)
        self.assertEqual(self.env_file.read_bytes(), expected)
        self.assertIn(b"EIGENINFERENCE_IPAPI_KEY=fixture-eigeninference-ipapi-key", expected)
        self.assertEqual(self.env_file.stat().st_mode & 0o777, 0o600)
        self.assert_clean()

    def test_missing_critical_secret_preserves_environment_on_both_paths(self):
        for secret in ("admin-key", "database-url", "stripe-secret-key",
                       "stripe-webhook-secret", "stripe-connect-webhook-secret"):
            for boot in (False, True):
                with self.subTest(secret=secret, boot=boot):
                    self.env_file.write_text("KEEP=existing-secret\n")
                    self.env["MISSING_SECRET"] = f"eigeninference-{secret}"
                    result = self.run_phase(boot)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(self.env_file.read_text(), "KEEP=existing-secret\n")
                    self.assertNotIn("existing-secret", result.stdout + result.stderr)
                    self.assert_clean()

    def test_missing_metadata_preserves_environment_and_cleans_download(self):
        self.env_file.write_text("KEEP=existing-secret\n")
        self.env["METADATA_FAIL"] = "1"
        result = self.run_phase(boot=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.env_file.read_text(), "KEEP=existing-secret\n")
        self.assert_clean()

    def test_optional_secret_may_be_absent(self):
        self.env["MISSING_SECRET"] = "eigeninference-ipapi-key"
        result = self.run_phase(boot=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("EIGENINFERENCE_IPAPI_KEY=\n", self.env_file.read_text())
        self.assert_clean()


if __name__ == "__main__":
    unittest.main()
