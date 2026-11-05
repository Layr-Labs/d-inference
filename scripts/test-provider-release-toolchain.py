#!/usr/bin/env python3
"""Exercise toolchain selection/argument propagation without installing software."""
import json
import os
import shutil
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

    def test_old_swift_cannot_select_sdk_27(self):
        self.compiler.write_text("#!/usr/bin/env bash\necho 'Apple Swift version 6.3'\n")
        result = self.select()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "env").exists())



class ReleaseCMakeTests(unittest.TestCase):
    """The image's tool-cache CMake is used when complete and exact; otherwise download."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="release cmake ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        stubs = self.root / "bin"
        stubs.mkdir()
        # An Apple Silicon Mac whose network refuses, recording each download.
        (stubs / "uname").write_text('#!/bin/sh\ncase "$1" in -s) echo Darwin ;; -m) echo arm64 ;; esac\n')
        (stubs / "curl").write_text(f'#!/bin/sh\necho "$@" >> "{self.root}/curl.log"\nexit 7\n')
        for stub in stubs.iterdir():
            stub.chmod(0o755)
        self.cache = self.root / "toolcache"
        self.env = {**os.environ, "PATH": f"{stubs}:{os.environ['PATH']}", "RUNNER_TOOL_CACHE": str(self.cache),
                    "RUNNER_TEMP": str(self.root), "GITHUB_PATH": str(self.root / "path")}

    def provision(self, version="3.31.12", complete=True):
        cmake = self.cache / "cmake/3.31.12/universal/CMake.app/Contents/bin/cmake"
        cmake.parent.mkdir(parents=True)
        cmake.write_text(f"#!/bin/sh\necho 'cmake version {version}'\n")
        cmake.chmod(0o755)
        if complete:
            (self.cache / "cmake/3.31.12/universal.complete").touch()
        return cmake.parent

    def install(self):
        return subprocess.run([str(ROOT / "scripts/install-release-cmake.sh")], env=self.env,
                              text=True, capture_output=True)

    def test_uses_the_complete_exact_tool_cache_copy_without_downloading(self):
        cached = self.provision()
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / "path").read_text(), f"{cached}\n")
        self.assertFalse((self.root / "curl.log").exists())

    def test_downloads_when_the_tool_cache_copy_is_absent_incomplete_or_another_version(self):
        for case in ("absent", "incomplete", "another version"):
            with self.subTest(case=case):
                shutil.rmtree(self.cache, ignore_errors=True)
                for leftover in ("curl.log", "path"):
                    (self.root / leftover).unlink(missing_ok=True)
                if case != "absent":
                    self.provision(version="3.30.0" if case == "another version" else "3.31.12",
                                   complete=case != "incomplete")
                result = self.install()
                # The refused download fails the step; nothing reaches PATH.
                self.assertEqual(result.returncode, 7, result.stderr)
                self.assertIn("/v3.31.12/cmake-3.31.12-macos-universal.tar.gz", (self.root / "curl.log").read_text())
                self.assertFalse((self.root / "path").exists())

if __name__ == "__main__":
    unittest.main()
