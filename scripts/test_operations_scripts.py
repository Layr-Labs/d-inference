"""Exercise operations CLIs with stub transports; no network or fleet mutations."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class OperationsScriptsTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.log = self.root / "calls.jsonl"
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.env = {**os.environ, "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
                    "OPERATIONS_TEST_LOG": str(self.log), "EIGENINFERENCE_ADMIN_KEY": "fixture-only"}

    def stub(self, name, source):
        path = self.bin / name
        path.write_text("#!/usr/bin/env python3\n" + source)
        path.chmod(0o755)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def test_admin_auth_and_deactivation_encode_user_values(self):
        self.stub("curl", '''import json,os,sys
with open(os.environ["OPERATIONS_TEST_LOG"], "a") as log:
    log.write(json.dumps(sys.argv[1:]) + "\\n")
print("{}")
''')
        email, code = 'person"\\name@example.invalid', '\\123"456'
        result = subprocess.run(["bash", str(ROOT / "scripts/admin.sh"), "login"],
                                input=email + "\n" + code + "\n", env=self.env,
                                capture_output=True, text=True)
        # The stub returns no token, so login intentionally stops before any token write.
        self.assertEqual(result.returncode, 1)
        init, verify = self.calls()
        self.assertEqual(json.loads(init[init.index("-d") + 1]), {"email": email})
        self.assertEqual(json.loads(verify[verify.index("-d") + 1]), {"email": email, "code": code})
        version, platform = '0.9.2"', 'macos\\arm64'
        result = subprocess.run(["bash", str(ROOT / "scripts/admin.sh"), "releases", "deactivate", version, platform],
                                env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        call = self.calls()[-1]
        self.assertEqual(json.loads(call[call.index("-d") + 1]), {"version": version, "platform": platform})


if __name__ == "__main__":
    unittest.main()
