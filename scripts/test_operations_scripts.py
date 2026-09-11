"""Exercise operations CLIs with stub transports; no network or fleet mutations."""

import json
import os
from pathlib import Path
import shutil
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

    def test_fleet_continues_after_failure_but_returns_failure(self):
        fleet = self.root / "update-fleet.sh"
        shutil.copy2(ROOT / "deploy/provider-fleet/update-fleet.sh", fleet)
        (self.root / "dev-inventory.txt").write_text("first\nsecond\nthird\n")
        self.stub("ssh", '''import json,os,sys
with open(os.environ["OPERATIONS_TEST_LOG"], "a") as log:
    log.write(json.dumps(sys.argv[1]) + "\\n")
sys.exit(1 if sys.argv[1] == "second" else 0)
''')
        result = subprocess.run(["bash", str(fleet), "dev"], env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.calls(), ["first", "second", "third"])
        self.assertIn("1 failed host", result.stderr)
        result = subprocess.run(["bash", str(fleet), "prod"], env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.calls(), ["first", "second", "third"])

    def test_smoke_uses_a_fresh_owned_response_file_and_removes_it(self):
        self.stub("curl", '''import json,os,sys
from pathlib import Path
args = sys.argv[1:]
if "-o" in args:
    path = args[args.index("-o") + 1]
    Path(path).write_text("fixture response")
    with open(os.environ["OPERATIONS_TEST_LOG"], "a") as log:
        log.write(json.dumps(path) + "\\n")
    print("500", end="")
elif args[-1].endswith("/v1/stats"):
    print('{"providers_online": 1}')
elif args[-1].endswith("/v1/models/catalog"):
    print('{"models": [1]}')
elif args[-1].endswith("/install.sh"):
    print("https://api.dev.darkbloom.xyz")
''')
        for _ in range(2):
            result = subprocess.run(["bash", str(ROOT / "scripts/smoke-dev.sh")],
                                    env={**self.env, "API_KEY": "fixture-only"}, capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn("fixture response", result.stdout)
        paths = self.calls()
        self.assertEqual(len(set(paths)), 2)
        self.assertTrue(all(not Path(path).exists() for path in paths))


if __name__ == "__main__":
    unittest.main()
