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


def read_github_env(path):
    """The KEY=value lines the toolchain step wrote to GITHUB_ENV."""
    return dict(line.split("=", 1) for line in path.read_text().splitlines())


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
        selected_env = self.selected_env()
        wrapper = Path((self.root / "path").read_text().strip()) / "swift"
        result = subprocess.run([str(wrapper), "test", "--skip-build", "--filter", "test with spaces"],
                                env={**self.env, **selected_env}, text=True, capture_output=True, check=True)
        self.assertEqual(json.loads(result.stdout), {"args": ["test", "--build-system", "native", "--sdk", str(self.sdk),
                                                              "--skip-build", "--filter", "test with spaces"], "sdk": str(self.sdk)})
        version = subprocess.run([str(wrapper), "--version"], env={**self.env, **selected_env},
                                 text=True, capture_output=True, check=True)
        self.assertIn("Apple Swift version 6.4", version.stdout)
        self.assertEqual(selected_env["PROVIDER_SDK_VERSION"], "27.0")
        self.assertNotIn("DEVELOPER_DIR", selected_env)

    def selected_env(self):
        return read_github_env(self.root / "env")

    def write_swift(self, compiler, version):
        compiler.parent.mkdir(parents=True, exist_ok=True)
        compiler.write_text(f"#!/bin/sh\necho 'Apple Swift version {version} (test fixture)'\n")
        compiler.chmod(0o755)

    def test_qualification_accepts_sdk_27_0_and_27_2(self):
        for settings, swift, recorded in (("27.0", "6.4", "27.0"), ("27.0.0", "6.4.1", "27.0"),
                                          ("27.2", "6.4.2", "27.2"), ("27.2.0", "6.4.2", "27.2")):
            with self.subTest(sdk=settings, swift=swift):
                (self.root / "env").unlink(missing_ok=True)
                (self.sdk / "SDKSettings.json").write_text(json.dumps({"Version": settings}))
                self.write_swift(self.compiler, swift)
                result = self.select()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.selected_env()["PROVIDER_SDK_VERSION"], recorded)
                self.assertIn(f"Selected provider release SDK {recorded} and Swift 6.4", result.stdout)

    def test_release_accepts_only_sdk_27_2_with_swift_6_4_2(self):
        self.env["DARKBLOOM_PROVIDER_TOOLCHAIN"] = "release"
        for settings, swift, accepted in (("27.2", "6.4.2", True), ("27.2", "6.4.2.1", True),
                                          ("27.0", "6.4.2", False), ("27.2", "6.4", False),
                                          ("27.2", "6.4.20", False)):
            with self.subTest(sdk=settings, swift=swift):
                (self.root / "env").unlink(missing_ok=True)
                (self.sdk / "SDKSettings.json").write_text(json.dumps({"Version": settings}))
                self.write_swift(self.compiler, swift)
                result = self.select()
                if accepted:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(self.selected_env()["PROVIDER_SDK_VERSION"], "27.2")
                else:
                    self.assertEqual(result.returncode, 1)
                    self.assertIn("requires preinstalled SDK 27.2 / Swift 6.4.2", result.stderr)
                    self.assertFalse((self.root / "env").exists())

    def test_unknown_toolchain_mode_is_refused(self):
        self.env["DARKBLOOM_PROVIDER_TOOLCHAIN"] = "beta"
        result = self.select()
        self.assertEqual(result.returncode, 2)
        self.assertIn("Unknown DARKBLOOM_PROVIDER_TOOLCHAIN: beta", result.stderr)
        self.assertFalse((self.root / "env").exists())

    def test_wrong_sdk_cannot_fall_back(self):
        for settings in ('{"Version":"26.5"}', '{"Version":"27.1"}', '{"Version":"27.3"}', '{}', 'not json'):
            with self.subTest(settings=settings):
                (self.sdk / "SDKSettings.json").write_text(settings)
                result = self.select()
                self.assertEqual(result.returncode, 1)
                self.assertIn("requires preinstalled SDK 27.2 or 27.0 / Swift 6.4", result.stderr)
                self.assertFalse((self.root / "env").exists())

    def test_old_or_unparsable_swift_cannot_select_sdk_27(self):
        for script in ("echo 'Apple Swift version 6.3'", "echo 'Apple Swift version 6.40'",
                       "echo 'swift-driver version: 1.168.6'", "exit 3"):
            with self.subTest(swift=script):
                self.compiler.write_text(f"#!/usr/bin/env bash\n{script}\n")
                result = self.select()
                self.assertEqual(result.returncode, 1)
                self.assertFalse((self.root / "env").exists())

    def test_clt_prefers_the_sdk_27_2_directory(self):
        del self.env["DARKBLOOM_RELEASE_SDK_ROOT"]
        for version in ("27.0", "27.2"):
            sdk = self.tool / "SDKs" / f"MacOSX{version}.sdk"
            sdk.mkdir(parents=True)
            (sdk / "SDKSettings.json").write_text(json.dumps({"Version": version}))
        result = self.select()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.selected_env()["PROVIDER_SDKROOT"], str(self.tool / "SDKs/MacOSX27.2.sdk"))
        self.assertEqual(self.selected_env()["PROVIDER_SDK_VERSION"], "27.2")


class XcodeSelectionTests(unittest.TestCase):
    """The image's Xcode, or another installed Xcode with the preferred SDK."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="xcode selection ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.applications = self.root / "Applications"
        stubs = self.root / "bin"
        stubs.mkdir()
        # xcrun answers for the developer directory in DEVELOPER_DIR, as Apple's does.
        (stubs / "xcrun").write_text(
            '#!/bin/sh\n: "${DEVELOPER_DIR:?}"\n'
            'case "$*" in\n'
            '  "--sdk macosx --find swift") echo "$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift" ;;\n'
            '  "--sdk macosx --show-sdk-path") echo "$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk" ;;\n'
            '  *) exit 64 ;;\nesac\n')
        (stubs / "xcode-select").write_text('#!/bin/sh\ntest "$1" = -p && echo "$IMAGE_DEVELOPER_DIR"\n')
        (stubs / "xcodebuild").write_text('#!/bin/sh\necho "xcodebuild for $DEVELOPER_DIR"\n')
        for stub in stubs.iterdir():
            stub.chmod(0o755)
        self.env = {key: value for key, value in os.environ.items() if key != "DEVELOPER_DIR"}
        self.env.update({"PATH": f"{stubs}:{os.environ['PATH']}", "GITHUB_ACTIONS": "false",
                         "GITHUB_ENV": str(self.root / "env"), "GITHUB_PATH": str(self.root / "path"),
                         "RUNNER_TEMP": str(self.root), "GITHUB_WORKSPACE": str(ROOT),
                         "DARKBLOOM_XCODE_APPLICATIONS": str(self.applications)})

    def install(self, name, sdk, swift):
        developer = self.applications / f"{name}.app" / "Contents/Developer"
        compiler = developer / "Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
        compiler.parent.mkdir(parents=True)
        compiler.write_text(f"#!/bin/sh\necho 'Apple Swift version {swift} (test fixture)'\n")
        compiler.chmod(0o755)
        settings = developer / "Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/SDKSettings.json"
        settings.parent.mkdir(parents=True)
        settings.write_text(json.dumps({"Version": sdk}))
        return developer

    def select(self, mode="qualification", image=None, explicit=None):
        env = {**self.env, "DARKBLOOM_PROVIDER_TOOLCHAIN": mode, "IMAGE_DEVELOPER_DIR": str(image)}
        if explicit:
            env["DEVELOPER_DIR"] = str(explicit)
        result = subprocess.run([str(ROOT / "scripts/prepare-provider-release-toolchain.sh")],
                                env=env, text=True, capture_output=True)
        selected = read_github_env(self.root / "env") if (self.root / "env").exists() else {}
        return result, selected

    def test_prefers_an_installed_xcode_27_2_over_the_image_xcode(self):
        image = self.install("Xcode_27.0", "27.0", "6.4")
        newer = self.install("Xcode_27.2", "27.2", "6.4.2")
        self.install("Xcode_27.3_beta", "27.3", "6.5")
        for mode in ("qualification", "release"):
            with self.subTest(mode=mode):
                (self.root / "env").unlink(missing_ok=True)
                result, selected = self.select(mode, image=image)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(selected["DEVELOPER_DIR"], str(newer))
                self.assertEqual(selected["PROVIDER_SWIFT"],
                                 str(newer / "Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"))
                self.assertEqual(selected["PROVIDER_SDK_VERSION"], "27.2")
                self.assertIn(f"xcodebuild for {newer}", result.stdout)

    def test_qualification_keeps_the_image_xcode_27_1_when_nothing_newer_is_installed(self):
        image = self.install("Xcode_27.1", "27.0", "6.4")
        result, selected = self.select(image=image)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("DEVELOPER_DIR", selected)
        self.assertEqual(selected["PROVIDER_SDK_VERSION"], "27.0")

    def test_image_xcode_27_2_needs_no_developer_dir(self):
        image = self.install("Xcode_27.2", "27.2", "6.4.2")
        self.install("Xcode_27.1", "27.0", "6.4")
        result, selected = self.select("release", image=image)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("DEVELOPER_DIR", selected)
        self.assertEqual(selected["PROVIDER_SDK_VERSION"], "27.2")

    def test_release_without_xcode_27_2_names_the_installed_xcodes(self):
        image = self.install("Xcode_27.1", "27.0", "6.4")
        result, selected = self.select("release", image=image)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(selected, {})
        self.assertIn("requires preinstalled SDK 27.2 / Swift 6.4.2", result.stderr)
        self.assertIn(f"installed: {self.applications / 'Xcode_27.1.app'}", result.stderr)

    def test_an_explicit_developer_dir_is_the_only_candidate(self):
        chosen = self.install("Xcode_27.1", "27.0", "6.4")
        self.install("Xcode_27.2", "27.2", "6.4.2")
        result, selected = self.select(image=chosen, explicit=chosen)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("DEVELOPER_DIR", selected)
        self.assertEqual(selected["PROVIDER_SDK_VERSION"], "27.0")
        (self.root / "env").unlink()
        result, selected = self.select("release", image=chosen, explicit=chosen)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(selected, {})


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
