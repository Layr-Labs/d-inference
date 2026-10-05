#!/usr/bin/env python3
"""Exercise staging layouts/failures without compiling or initializing Metal."""
import os
import pathlib
import shlex
import shutil
import subprocess
import tempfile
import unittest

RUNTIME_LIBRARY_PATHS = ["Contents/MacOS/mlx.metallib",
                         "Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"]


class StageTestMetallibTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        self.scripts = self.root / "scripts"
        self.scripts.mkdir()
        source = pathlib.Path(__file__).with_name("stage-test-metallib.sh")
        self.stage = self.scripts / source.name
        shutil.copy2(source, self.stage)
        self.fetch = self.scripts / "fetch-metallib.sh"
        self.fetch.write_text('#!/bin/bash\nset -eu\nprintf verified-by-fetch > "$1/mlx.metallib"\n')
        self.fetch.chmod(0o755)
        self.bin = self.root / "build with spaces"
        self.bin.mkdir()
        self.env = os.environ.copy()

    def run_stage(self):
        return subprocess.run([str(self.stage), str(self.bin)], capture_output=True, text=True,
                              env=self.env)

    def fake_copy_platform(self, system, copy_body=None):
        tools = self.root / "tools"
        tools.mkdir(exist_ok=True)
        uname = tools / "uname"
        uname.write_text(f"#!/bin/bash\nprintf '%s\\n' {shlex.quote(system)}\n")
        uname.chmod(0o755)
        calls = tools / "copy-calls"
        calls.write_text("")
        cp = tools / "cp"
        flags = '[ "$1" = -c ]; shift' if system == "Darwin" else '[ "$1" != -c ]'
        if copy_body is None:
            copy_body = f'exec {shlex.quote(shutil.which("cp"))} "$@"'
        cp.write_text(f"#!/bin/bash\nset -eu\nprintf 'copy\\n' >> {shlex.quote(str(calls))}\n"
                      f"{flags}\n{copy_body}\n")
        cp.chmod(0o755)
        self.env["PATH"] = str(tools) + os.pathsep + os.environ["PATH"]
        return calls

    def assert_stages_every_bundle(self, bundle_names):
        paths = []
        for name in bundle_names:
            for relative in RUNTIME_LIBRARY_PATHS:
                path = self.bin / name / relative
                path.parent.mkdir(parents=True)
                path.write_text("stale")
                paths.append(path)
        result = self.run_stage()
        self.assertEqual(result.returncode, 0, result.stderr)
        for path in paths:
            self.assertEqual(path.read_text(), "verified-by-fetch")
        self.assertFalse(list(self.bin.rglob(".mlx-metallib.*")))

    def test_replaces_both_resource_layouts_for_every_package_bundle(self):
        self.assert_stages_every_bundle(["FirstPackageTests.xctest", "SecondPackageTests.xctest"])

    def test_replaces_both_resource_layouts_for_every_per_target_bundle(self):
        self.assert_stages_every_bundle(["ProviderCoreTests.xctest", "DarkbloomCLITests.xctest"])

    def test_stages_per_target_bundle_without_prior_library(self):
        bundle = self.bin / "ProviderCoreTests.xctest"
        (bundle / "Contents/MacOS").mkdir(parents=True)
        result = self.run_stage()
        self.assertEqual(result.returncode, 0, result.stderr)
        for relative in RUNTIME_LIBRARY_PATHS:
            self.assertEqual((bundle / relative).read_text(), "verified-by-fetch")

    def test_copy_flags_match_platform(self):
        for system in ("Darwin", "Linux", "FreeBSD"):
            with self.subTest(system=system):
                calls = self.fake_copy_platform(system)
                self.assert_stages_every_bundle([f"{system}Tests.xctest"])
                self.assertEqual(len(calls.read_text().splitlines()),
                                 len(list(self.bin.glob("*.xctest"))) * len(RUNTIME_LIBRARY_PATHS))

    def test_copy_and_verification_failures_preserve_destination_and_clean_staging(self):
        path = self.bin / "OnlyPackageTests.xctest/Contents/MacOS/mlx.metallib"
        path.parent.mkdir(parents=True)
        for system in ("Darwin", "Linux"):
            for copy_exit in (23, 0):
                with self.subTest(system=system, copy_exit=copy_exit):
                    path.write_text("prior-runtime")
                    calls = self.fake_copy_platform(
                        system, f'printf partial > "$2"\nexit {copy_exit}')
                    result = self.run_stage()
                    self.assertEqual(result.returncode, copy_exit or 1, result.stderr)
                    self.assertEqual(path.read_text(), "prior-runtime")
                    self.assertFalse(list(self.bin.rglob(".mlx-metallib.*")))
                    self.assertEqual(calls.read_text(), "copy\n")

    def test_no_runner_cannot_be_reported_as_success(self):
        self.assertNotEqual(self.run_stage().returncode, 0)

    def test_failed_source_verification_never_stages_stale_library(self):
        path = self.bin / "OnlyPackageTests.xctest/Contents/MacOS/mlx.metallib"
        path.parent.mkdir(parents=True)
        path.write_text("prior-runtime")
        (self.bin / "mlx.metallib").write_text("stale-build")
        self.fetch.write_text("#!/bin/bash\nexit 7\n")
        self.assertEqual(self.run_stage().returncode, 7)
        self.assertEqual(path.read_text(), "prior-runtime")

    def test_cache_identity_includes_downloadable_metal_compiler(self):
        source = pathlib.Path(__file__).with_name("fetch-metallib.sh").read_text()
        identity = source.split('TOOLCHAIN_HASH="$(')[1].split('CACHE_DIR=')[0]
        self.assertIn('"$METAL_VERSION"', identity)
        self.assertIn('"metal=$METAL_COMPILER_HASH"', identity)
        self.assertIn('xcrun --no-cache --sdk macosx metal --version', source)
        self.assertIn('shasum -a 256 "$METAL_COMPILER"', source)
        self.assertIn("METAL_VERSION=\"${METAL_VERSION%%$'\\n'*}\"", source)

    def test_release_outer_cache_matches_downloadable_compiler_identity(self):
        root = pathlib.Path(__file__).resolve().parent.parent
        action = (root / ".github/actions/provider-release-build/action.yml").read_text()
        self.assertLess(action.index("Ensure matching Metal compiler is available"),
                        action.index("Resolve source-matched metallib cache namespace"))
        namespace = action.split("Resolve source-matched metallib cache namespace", 1)[1].split("Restore source-matched", 1)[0]
        self.assertIn("xcrun --no-cache --sdk macosx --find metal", namespace)
        self.assertIn('shasum -a 256 "$METAL_COMPILER"', namespace)
        self.assertIn("${METAL_SHA}", namespace)


if __name__ == "__main__":
    unittest.main()
