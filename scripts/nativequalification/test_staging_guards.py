#!/usr/bin/env python3
"""Exercise the local signing entry guards without using signing material."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("stage-signed-app.sh")


class StagingGuards(unittest.TestCase):
    def run_script(self, arguments, enabled=False):
        environment = {"PATH": os.environ["PATH"]}
        if enabled:
            environment["DARKBLOOM_NATIVE_APP_ATTEST_QUALIFICATION"] = "1"
        return subprocess.run(
            ["bash", str(SCRIPT), *arguments], env=environment,
            capture_output=True, text=True, timeout=5, check=False)

    def test_signing_requires_explicit_opt_in(self):
        result = self.run_script(["unused"] * 6)
        self.assertEqual(result.returncode, 64)
        self.assertIn("Requires DARKBLOOM_NATIVE_APP_ATTEST_QUALIFICATION=1", result.stderr)

    def test_signing_requires_complete_inputs(self):
        result = self.run_script([], enabled=True)
        self.assertEqual(result.returncode, 64)

    def test_output_outside_worktree_is_rejected_before_signing(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            binary = root / "bin"
            binary.mkdir()
            payload = root / "unused-payload"
            payload.write_bytes(b"not signing material")
            output = root / "must-not-exist"
            result = self.run_script([
                str(binary), str(payload), str(output), str(payload), "unused-identity", "0.0.0"
            ], enabled=True)
            self.assertEqual(result.returncode, 64)
            self.assertIn("inside this provider worktree .build", result.stderr)
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
