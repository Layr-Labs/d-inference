#!/usr/bin/env python3
"""Validate the real macOS resource copier and its unchanged sealed layout."""
import os
import pathlib
import plistlib
import subprocess
import sys
import tempfile
import unittest


@unittest.skipUnless(sys.platform == "darwin", "macOS signed-app packaging")
class SwiftPMResourceBundleTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = pathlib.Path(temporary.name)
        self.binaries = self.root / "build with spaces"
        self.binaries.mkdir()
        self.app = self.root / "Candidate.app"
        self.app.mkdir()
        self.manifest = self.root / "manifest.txt"
        self.script = pathlib.Path(__file__).with_name("stage-swiftpm-resource-bundles.sh")

    def bundle(self, name, nested):
        bundle = self.binaries / name
        resources = bundle / "Contents/Resources" if nested else bundle
        resources.mkdir(parents=True)
        (resources / "pagedattention.metal").write_bytes(b"exact packed and native source\n")
        preambles = resources / "Qwen4Metal"
        preambles.mkdir()
        (preambles / "gemm.metal").write_bytes(b"exact preamble\n")
        if nested:
            (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundlePackageType": "BNDL"}))
        return bundle

    def stage(self, env=None):
        return subprocess.run([str(self.script), str(self.binaries), str(self.app), str(self.manifest)],
            capture_output=True, text=True, env=env)

    def check_layout(self, nested):
        source = self.bundle("mlx-swift-lm_MLXLMCommon.bundle", nested)
        result = self.stage()
        self.assertEqual(result.returncode, 0, result.stderr)
        staged = self.app / "Contents/Resources" / source.name
        self.assertEqual((staged / "pagedattention.metal").read_bytes(), b"exact packed and native source\n")
        self.assertEqual((staged / "Qwen4Metal/gemm.metal").read_bytes(), b"exact preamble\n")
        self.assertFalse((staged / "Contents").exists())
        self.assertEqual(self.manifest.read_text(), source.name + "\n")
        marker = self.app / "Contents/Resources/darkbloom-runtime-capabilities/paged-kernel-v1"
        self.assertEqual(marker.read_text(), "1\n")
        original = source / "Contents/Resources/pagedattention.metal" if nested else source / "pagedattention.metal"
        self.assertEqual(original.read_bytes(), b"exact packed and native source\n")

    def test_flat_layout_keeps_the_published_contract(self):
        self.check_layout(False)

    def test_nested_swift_build_layout_becomes_one_sealed_source(self):
        self.check_layout(True)

    def test_executable_bundle_is_not_flattened_as_resources(self):
        source = self.bundle("mlx-swift-lm_MLXLMCommon.bundle", True)
        (source / "Contents/MacOS").mkdir()
        result = self.stage()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("executable code", result.stderr)
        self.assertFalse((self.app / "Contents/Resources/darkbloom-runtime-capabilities/paged-kernel-v1").exists())

    def test_flat_resource_bundle_also_rejects_executable_contents(self):
        source = self.bundle("mlx-swift-lm_MLXLMCommon.bundle", False)
        (source / "Contents/MacOS").mkdir(parents=True)
        result = self.stage()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("executable code", result.stderr)

    def test_normalization_failure_removes_its_owned_temporary_directory(self):
        self.bundle("mlx-swift-lm_MLXLMCommon.bundle", True)
        commands = self.root / "failing command"
        commands.mkdir()
        move = commands / "mv"
        move.write_text("#!/bin/sh\nexit 93\n")
        move.chmod(0o755)
        environment = {**os.environ, "PATH": str(commands) + os.pathsep + os.environ["PATH"]}
        result = self.stage(env=environment)
        self.assertEqual(result.returncode, 93, result.stderr)
        resources = self.app / "Contents/Resources"
        self.assertEqual(list(resources.glob(".swiftpm-resource.*")), [])


if __name__ == "__main__":
    unittest.main()
