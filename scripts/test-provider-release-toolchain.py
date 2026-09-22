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

    def test_wrong_sdk_cannot_fall_back(self):
        (self.sdk / "SDKSettings.json").write_text('{"Version":"26.5"}')
        result = self.select()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("requires preinstalled SDK 27", result.stderr)
        self.assertFalse((self.root / "env").exists())

    def use_xcode(self):
        del self.env["DARKBLOOM_RELEASE_TOOLCHAIN_ROOT"]
        del self.env["DARKBLOOM_RELEASE_SDK_ROOT"]
        self.env["DEVELOPER_DIR"] = str(self.root / "Xcode 27.app/Contents/Developer")
        self.env["PATH"] = str(self.root) + os.pathsep + self.env["PATH"]
        self.env["TEST_COMPILER"] = str(self.compiler)
        self.env["TEST_SDK"] = str(self.sdk)
        xcrun = self.root / "xcrun"
        xcrun.write_text("#!/usr/bin/env bash\nset -eu\n"
                          'case "$*" in\n'
                          '  "--sdk macosx --find swift") echo "$TEST_COMPILER" ;;\n'
                          '  "--sdk macosx --show-sdk-path") echo "$TEST_SDK" ;;\n'
                          '  *) exit 9 ;;\nesac\n')
        xcrun.chmod(0o755)
        xcodebuild = self.root / "xcodebuild"
        xcodebuild.write_text("#!/usr/bin/env bash\necho 'Xcode 27.0'\n")
        xcodebuild.chmod(0o755)

    def test_explicit_xcode_selects_its_compiler_and_sdk(self):
        self.use_xcode()
        selected = self.select()
        self.assertEqual(selected.returncode, 0, selected.stderr)
        env = (self.root / "env").read_text()
        self.assertIn(f"PROVIDER_SWIFT={self.compiler}\n", env)
        self.assertIn(f"PROVIDER_SDKROOT={self.sdk}\n", env)

    def test_explicit_xcode_with_old_sdk_fails_closed(self):
        self.use_xcode()
        (self.sdk / "SDKSettings.json").write_text('{"Version":"26.5"}')
        self.assertNotEqual(self.select().returncode, 0)
        self.assertFalse((self.root / "env").exists())

    def test_missing_xcode_cannot_fall_back_to_clt(self):
        self.use_xcode()
        (self.root / "xcrun").write_text("#!/usr/bin/env bash\nexit 1\n")
        self.assertNotEqual(self.select().returncode, 0)
        self.assertFalse((self.root / "env").exists())

    def test_old_swift_cannot_select_sdk_27(self):
        self.compiler.write_text("#!/usr/bin/env bash\necho 'Apple Swift version 6.3'\n")
        result = self.select()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "env").exists())


if __name__ == "__main__":
    unittest.main()
