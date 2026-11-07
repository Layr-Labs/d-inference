#!/usr/bin/env python3
"""Offline checks of the test products hand-off with the real git, tar and zstd.

The toolchain probe asks Xcode, which a Linux gate has not; the tests give it
fixed values. The fixed build path is a temporary directory here.
"""

import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("ci_test_products", ROOT / "scripts/ci-test-products.py")
products = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(products)

TOOLCHAIN = {"versions": {"swift": "6.4.2", "xcode": "Xcode 27.2", "sdk": "27.2"},
             "builds": {"swift": "Apple Swift version 6.4.2 (swiftlang-6.4.2.1.4)", "xcode": "Build version 27B5038j",
                        "sdk": "26B5110a"}}
DEBUG = ".build/arm64-apple-macosx/debug"
BUNDLE = f"{DEBUG}/ProviderPackageTests.xctest/Contents"
KEPT = (f"{BUNDLE}/MacOS/ProviderPackageTests", f"{DEBUG}/darkbloom",
        f"{DEBUG}/Provider_Resources.bundle/model.json", f"{DEBUG}/mlx.metallib", f"{BUNDLE}/MacOS/mlx.metallib",
        f"{BUNDLE}/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib",
        ".build/checkouts/swift-nio/Sources/NIO.swift", ".build/checkouts/swift-nio/Tests.build/kept",
        ".build/checkouts/swift-nio/.git/objects/info/alternates", ".build/checkouts/swift-syntax/Macros-tool",
        ".build/build.db", f"{DEBUG}/description.json", ".build/workspace-state.json")
# The compile intermediates, the debug symbols (beside an executable and
# inside the test bundle), the host tools and SwiftPM's bare clones.
DROPPED = (f"{DEBUG}/ProviderCore.build/Engine.swift.o", f"{DEBUG}/ModuleCache/Foundation.pcm",
           f"{DEBUG}/index/store/v5/units", f"{DEBUG}/Modules/ProviderCore.swiftmodule",
           f"{DEBUG}/darkbloom.dSYM/Contents/Resources/DWARF/darkbloom",
           f"{BUNDLE}/MacOS/ProviderPackageTests.dSYM/Contents/Resources/DWARF/ProviderPackageTests",
           f"{DEBUG}/Macros-tool", f"{DEBUG}/Macros-tool.product/Objects.LinkFileList",
           f"{DEBUG}/Modules-tool/SwiftSyntax.swiftmodule", ".build/repositories/swift-nio-1234/HEAD")


def git(root, *args):
    subprocess.run(["git", "-C", str(root), "-c", "user.name=t", "-c", "user.email=t@t",
                    "-c", "commit.gpgsign=false", *args], check=True, capture_output=True)


class TestProductsTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="ci-test-products-")
        self.addCleanup(temporary.cleanup)
        self.fixed = Path(temporary.name).resolve() / "dinf"
        self.package = self.fixed / "provider-swift"
        self.package.mkdir(parents=True)
        (self.package / "Package.swift").write_text("// package\n")
        git(self.fixed, "init", "-q")
        git(self.fixed, "add", "-A")
        git(self.fixed, "commit", "-q", "-m", "tree")
        for relative in KEPT + DROPPED:
            path = self.package / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(relative)
        for executable in KEPT[:2]:
            (self.package / executable).chmod(0o755)
        (self.package / ".build/debug").symlink_to("arm64-apple-macosx/debug")
        self.archive = Path(temporary.name) / "out" / "provider.tar.zst"
        self.environment = Path(temporary.name) / "github-env"
        for patch in (mock.patch.object(products, "FIXED_ROOT", self.fixed),
                      mock.patch.object(products, "toolchain", lambda: json.loads(json.dumps(TOOLCHAIN))),
                      mock.patch.dict(os.environ, {"GITHUB_ENV": str(self.environment)})):
            patch.start()
            self.addCleanup(patch.stop)

    def run_main(self, *argv, root=None):
        printed = io.StringIO()
        with contextlib.redirect_stdout(printed):
            status = products.main(["--root", str(root or self.fixed), *argv])
        return status, printed.getvalue()

    def pack_and_clear(self):
        self.assertEqual(self.run_main("pack", "provider", str(self.archive))[0], 0)
        shutil.rmtree(self.package / ".build")

    def test_round_trip_keeps_the_products_and_drops_the_compile_intermediates(self):
        status, printed = self.run_main("pack", "provider", str(self.archive))
        self.assertEqual(status, 0, printed)
        self.assertIn("MiB of files", printed)
        self.assertIn("MiB compressed", printed)
        self.assertIn(f"{products.STAMP}=", self.environment.read_text())
        shutil.rmtree(self.package / ".build")
        with mock.patch.dict(os.environ, {products.STAMP: "0"}):
            status, printed = self.run_main("unpack", "provider", str(self.archive))
        self.assertEqual(status, 0, printed)
        self.assertIn("downloaded in", printed)
        for relative in KEPT:
            self.assertEqual((self.package / relative).read_text(), relative)
        for relative in DROPPED:
            self.assertFalse((self.package / relative).exists(), relative)
        for executable in KEPT[:2]:
            self.assertTrue(os.access(self.package / executable, os.X_OK), executable)
        link = self.package / ".build/debug"
        self.assertTrue(link.is_symlink())
        self.assertEqual(os.readlink(link), "arm64-apple-macosx/debug")
        status, printed = self.run_main("uploaded", str(self.archive))
        self.assertEqual(status, 0, printed)

    def test_products_of_another_toolchain_version_or_commit_are_refused(self):
        self.pack_and_clear()
        # Another build of the same versions (the release Xcode 27.2 against a
        # pre-release one, run 42037827790) warns and runs the products.
        other = {"versions": TOOLCHAIN["versions"], "builds": {**TOOLCHAIN["builds"], "xcode": "Build version 27B52"}}
        with mock.patch.object(products, "toolchain", lambda: other):
            status, printed = self.run_main("unpack", "provider", str(self.archive))
        self.assertEqual(status, 0, printed)
        self.assertIn("::warning title=Test products::", printed)
        self.assertIn("27B52", printed)
        shutil.rmtree(self.package / ".build")
        other = {"versions": {**TOOLCHAIN["versions"], "xcode": "Xcode 27.1"}, "builds": TOOLCHAIN["builds"]}
        with mock.patch.object(products, "toolchain", lambda: other):
            status, printed = self.run_main("unpack", "provider", str(self.archive))
        self.assertEqual(status, 1)
        self.assertIn("::error title=Test products::", printed)
        self.assertIn("one toolchain", printed)
        shutil.rmtree(self.package / ".build")
        git(self.fixed, "commit", "-q", "--allow-empty", "-m", "later")
        status, printed = self.run_main("unpack", "provider", str(self.archive))
        self.assertEqual(status, 1)
        self.assertIn("commit", printed)

    def test_a_test_job_never_unpacks_over_a_build_or_without_an_archive(self):
        self.assertEqual(self.run_main("pack", "provider", str(self.archive))[0], 0)
        status, printed = self.run_main("unpack", "provider", str(self.archive))
        self.assertEqual(status, 1)
        self.assertIn("already exists", printed)
        status, printed = self.run_main("unpack", "provider", str(self.archive.with_name("missing.tar.zst")))
        self.assertEqual(status, 1)
        self.assertIn("download did not complete", printed)

    def test_products_outside_the_fixed_path_unknown_lanes_and_missing_builds_are_refused(self):
        elsewhere = self.fixed.parent / "elsewhere"
        (elsewhere / "provider-swift/.build").mkdir(parents=True)
        status, printed = self.run_main("pack", "provider", str(self.archive), root=elsewhere)
        self.assertEqual(status, 1)
        self.assertIn("fixed build path", printed)
        status, printed = self.run_main("pack", "sdk", str(self.archive))
        self.assertEqual(status, 1)
        self.assertIn("Unknown lane", printed)
        status, printed = self.run_main("pack", "cluster", str(self.archive))
        self.assertEqual(status, 1)
        self.assertIn("did not build", printed)
        self.assertFalse(self.archive.exists())

    def test_a_failed_archive_command_fails_the_step(self):
        # A corrupt archive: zstd fails, and so does the step.
        shutil.rmtree(self.package / ".build")
        self.archive.parent.mkdir(parents=True)
        self.archive.write_bytes(b"not zstd")
        status, printed = self.run_main("unpack", "provider", str(self.archive))
        self.assertEqual(status, 1)
        self.assertIn("failed (exit", printed)


if __name__ == "__main__":
    unittest.main()
