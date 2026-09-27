#!/usr/bin/env python3
"""Exercise staging layouts/failures without compiling or initializing Metal."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest


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

    def run_stage(self):
        return subprocess.run([str(self.stage), str(self.bin)], capture_output=True, text=True)

    def test_replaces_both_resource_layouts_for_every_bundle(self):
        paths = []
        for name in ["FirstPackageTests.xctest", "SecondPackageTests.xctest"]:
            for relative in ["Contents/MacOS/mlx.metallib",
                             "Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"]:
                path = self.bin / name / relative
                path.parent.mkdir(parents=True)
                path.write_text("stale")
                paths.append(path)
        result = self.run_stage()
        self.assertEqual(result.returncode, 0, result.stderr)
        for path in paths:
            self.assertEqual(path.read_text(), "verified-by-fetch")
        self.assertFalse(list(self.bin.rglob(".mlx-metallib.*")))

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


if __name__ == "__main__":
    unittest.main()
