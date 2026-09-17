#!/usr/bin/env python3
"""Run the real Qwen header accessor in a relocated app, without MLX or weights."""
import os
from pathlib import Path
import plistlib
import platform
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
COMMON = ROOT / "libs/mlx-swift-lm/Libraries/MLXLMCommon"
BUNDLE = "mlx-swift-lm_MLXLMCommon.bundle"


class PackagedQwenResourcesTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="qwen-packaged-resources-")
        cls.root = Path(cls.temporary.name)
        main = cls.root / "main.swift"
        main.write_text('''import Foundation
import CryptoKit
import Darwin
do {
    try Qwen4ExpMetalHeaders.validateResources()
    let sources = [
        (Qwen4ExpMetalHeaders.gemm, "cc2597fad25939505da77537ff15e78eba2fccbdf14a0e636fb2d2ac0bb4bb6c"),
        (Qwen4ExpMetalHeaders.quantizedUtils, "36893d020956fec4b63f37855035dfebc317bd06a966de14c6372c9a2971ef28"),
        (Qwen4ExpMetalHeaders.quantized, "d39dae2a27d0352facbe0e07c97af1ba0782a923698ce3931a92417d9e527162"),
    ]
    for (source, expected) in sources {
        let actual = SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
        guard actual == expected else { exit(2) }
    }
    print("qwen4-packaged-resources: ok")
} catch {
    FileHandle.standardError.write(Data("\\(error)\\n".utf8))
    exit(1)
}
''')
        cls.binary = cls.root / "built-probe"
        swift = os.environ.get("PROVIDER_SWIFT")
        compiler = str(Path(swift).with_name("swiftc")) if swift else "swiftc"
        # The release toolchain exports its SDK for SwiftPM's wrapper. A direct
        # swiftc invocation must bind it explicitly as well; the host default
        # SDK can belong to a different Xcode than the selected CLT compiler.
        sdk = os.environ.get("PROVIDER_SDKROOT") or subprocess.check_output(
            ["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
        subprocess.run([
            compiler, "-O", "-sdk", sdk,
            "-target", f"{platform.machine()}-apple-macosx14.0",
            str(COMMON / "ContinuousBatchingV2/Paged/PagedAttentionResources.swift"),
            str(COMMON / "Qwen4ExpMetalResources.swift"),
            str(COMMON / "Qwen4ExpMetalHeaders.swift"), str(main),
            "-o", str(cls.binary),
        ], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def setUp(self):
        self.case = self.root / self._testMethodName
        self.app = self.case / "relocated/Darkbloom.app"
        self.executable = self.app / "Contents/MacOS/probe"
        self.executable.parent.mkdir(parents=True)
        shutil.copy2(self.binary, self.executable)
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleExecutable": "probe", "CFBundleIdentifier": "io.darkbloom.resource-test",
            "CFBundlePackageType": "APPL",
        }))
        self.resources = self.app / "Contents/Resources" / BUNDLE / "Qwen4Metal"
        shutil.copytree(COMMON / "Resources/Qwen4Metal", self.resources)
        self.cwd = self.case / "unrelated-working-directory"
        self.cwd.mkdir()

    def run_probe(self, executable=None):
        return subprocess.run([str(executable or self.executable)], cwd=self.cwd,
                              capture_output=True, text=True)

    def test_relocated_app_uses_sealed_resources(self):
        result = self.run_probe()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("qwen4-packaged-resources: ok", result.stdout)

    def test_installer_symlink_resolves_to_the_app(self):
        link = self.case / "darkbloom"
        link.symlink_to(self.executable)
        result = self.run_probe(link)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_missing_header_does_not_fall_back_to_cwd_or_app_root(self):
        for root in [self.cwd, self.app, self.cwd / ".build/release"]:
            shutil.copytree(COMMON / "Resources/Qwen4Metal", root / BUNDLE / "Qwen4Metal")
        (self.resources / "gemm.metal").unlink()
        result = self.run_probe()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("missing or empty: gemm", result.stderr)

    def test_empty_resource_is_rejected(self):
        (self.resources / "quantized.metal").write_text("")
        result = self.run_probe()
        self.assertEqual(result.returncode, 1, result.stderr)

    def test_resource_symlink_cannot_escape_the_app(self):
        header = self.resources / "gemm.metal"
        header.unlink()
        header.symlink_to(COMMON / "Resources/Qwen4Metal/gemm.metal")
        result = self.run_probe()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("escapes the signed app", result.stderr)

    def test_unbundled_development_executable_still_works(self):
        executable = self.case / "development/probe"
        executable.parent.mkdir()
        shutil.copy2(self.binary, executable)
        shutil.copytree(COMMON / "Resources/Qwen4Metal",
                        executable.parent / BUNDLE / "Qwen4Metal")
        result = self.run_probe(executable)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
