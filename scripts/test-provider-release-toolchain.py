#!/usr/bin/env python3
"""Exercise toolchain selection/argument propagation without installing software."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent


class ReleaseToolchainTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="release toolchain ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.tool = self.root / "tools"
        self.sdk = self.root / "SDK 27"
        (self.tool / "usr/bin").mkdir(parents=True)
        self.sdk.mkdir()
        (self.sdk / "SDKSettings.json").write_text('{"Version":"27.0"}')
        self.compiler = self.tool / "usr/bin/swift"
        self.compiler.write_text("#!/usr/bin/env python3\nimport os,sys,json\n"
                                 "if sys.argv[1:]==['--version']: print('Apple Swift version 6.4 (test fixture)')\n"
                                 "else: print(json.dumps({'args':sys.argv[1:],'sdk':os.environ.get('SDKROOT')}))\n")
        self.compiler.chmod(0o755)
        self.env = {**os.environ, "GITHUB_ACTIONS": "false",
                    "GITHUB_ENV": str(self.root / "env"), "GITHUB_PATH": str(self.root / "path"),
                    "RUNNER_TEMP": str(self.root), "GITHUB_WORKSPACE": str(ROOT),
                    "DARKBLOOM_RELEASE_TOOLCHAIN_ROOT": str(self.tool), "DARKBLOOM_RELEASE_SDK_ROOT": str(self.sdk)}

    def select(self):
        return subprocess.run([str(ROOT / "scripts/prepare-provider-release-toolchain.sh")],
                              env=self.env, text=True, capture_output=True)

    def test_selects_exact_sdk_and_preserves_spaced_arguments(self):
        selected = self.select()
        self.assertEqual(selected.returncode, 0, selected.stderr)
        selected_env = dict(line.split("=", 1) for line in (self.root / "env").read_text().splitlines())
        wrapper = Path((self.root / "path").read_text().strip()) / "swift"
        result = subprocess.run([str(wrapper), "test", "--skip-build", "--filter", "test with spaces"],
                                env={**self.env, **selected_env}, text=True, capture_output=True, check=True)
        self.assertEqual(json.loads(result.stdout), {"args": ["test", "--build-system", "native", "--sdk", str(self.sdk),
                                                              "--skip-build", "--filter", "test with spaces"], "sdk": str(self.sdk)})
        version = subprocess.run([str(wrapper), "--version"], env={**self.env, **selected_env},
                                 text=True, capture_output=True, check=True)
        self.assertIn("Apple Swift version 6.4", version.stdout)

    def test_wrong_sdk_cannot_fall_back_or_install_outside_ci(self):
        (self.sdk / "SDKSettings.json").write_text('{"Version":"26.5"}')
        result = self.select()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("automatic installation is limited", result.stderr)
        self.assertFalse((self.root / "env").exists())

    def test_old_swift_cannot_select_sdk_27(self):
        self.compiler.write_text("#!/usr/bin/env bash\necho 'Apple Swift version 6.3'\n")
        result = self.select()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "env").exists())


if __name__ == "__main__":
    unittest.main()
