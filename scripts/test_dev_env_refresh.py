"""Exercise the boot env phase with local metadata and Secret Manager stubs."""

import os
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
