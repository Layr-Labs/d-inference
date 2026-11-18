#!/usr/bin/env python3
"""Offline tests of scripts/sign-desktop-app.py, the desktop release signer.

The first tests run the signer on a synthetic app with a recording stand-in for
codesign: what is signed, in which order and with which options.

The last test needs a Mac, a built unsigned app and desktop-app/node_modules,
and is skipped without them. It signs one copy of the app with the signer and
another with @electron/osx-sign under the options electron-builder passes it
(MacTargetHelper.buildSignOptions and getOptionsForFile in app-builder-lib),
both ad hoc so no certificate is involved, and requires the same code
signature on every signed path. release-desktop.yml runs it on the app it has
just built, in the job that holds no key:

    DARKBLOOM_DESKTOP_UNSIGNED_APP=desktop-app/release/mac-arm64/Darkbloom.app \\
      python3 scripts/test-sign-desktop-app.py
"""
import importlib.util
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts/sign-desktop-app.py"
ENTITLEMENTS = ROOT / "desktop-app/resources/entitlements.mac.plist"
SPEC = importlib.util.spec_from_file_location("sign_desktop_app", SCRIPT)
SIGNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SIGNER)

MACHO = bytes.fromhex("cffaedfe0c000001") + b"\0" * 24
UNIVERSAL = bytes.fromhex("cafebabe00000002") + b"\0" * 24
IDENTITY = "0123456789ABCDEF0123456789ABCDEF01234567"
UNSIGNED_APP = os.environ.get("DARKBLOOM_DESKTOP_UNSIGNED_APP")
NODE_MODULES = ROOT / "desktop-app/node_modules/@electron/osx-sign"

# Records every call; fails on the path named by STUB_FAIL_ON.
CODESIGN = r"""#!/bin/bash
printf '%s\n' "$*" >> "$STUB_LOG"
if [ -n "${STUB_FAIL_ON:-}" ] && [ "${@: -1}" = "$STUB_FAIL_ON" ]; then exit 1; fi
exit 0
"""

# What electron-builder passes to @electron/osx-sign for this app: the same
# entitlements for the app and everything in it, the hardened runtime, and its
# own list of paths that are never signed.
OSX_SIGN = """
const { signAsync } = require('@electron/osx-sign');
const [app, entitlements] = process.argv.slice(1);
signAsync({
  app, identity: '-', identityValidation: false, platform: 'darwin', type: 'distribution',
  ignore: (file) => file.endsWith('.kext') || file.startsWith('/Contents/PlugIns', app.length),
  optionsForFile: () => ({ entitlements, hardenedRuntime: true, additionalArguments: [] }),
}).catch((error) => { console.error(error); process.exit(1); });
"""


def write(path, data=MACHO, mode=0o755):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    path.chmod(mode)


def synthetic_app(root):
    """The shape of an Electron app: versioned frameworks, helper apps, resources."""
    app = root / "Darkbloom.app"
    contents = app / "Contents"
    write(contents / "MacOS/Darkbloom")
    write(contents / "Info.plist", b"<plist/>", 0o644)
    write(contents / "Resources/app.asar", b"\x04\x00\x00\x00 not code", 0o644)
    write(contents / "Resources/icon.icns", b"icns\x00\x01", 0o644)
    write(contents / "Resources/bootstrap/install-runtime.sh", b"#!/bin/bash\n")
    framework = contents / "Frameworks/Electron Framework.framework"
    write(framework / "Versions/A/Electron Framework", UNIVERSAL)
    write(framework / "Versions/A/Libraries/libEGL.dylib")
    write(framework / "Versions/A/Helpers/chrome_crashpad_handler")
    write(framework / "Versions/A/Resources/resources.pak", b"\x05\x00\x00\x00", 0o644)
    (framework / "Versions/Current").symlink_to("A")
    for name in ("Electron Framework", "Libraries", "Helpers", "Resources"):
        (framework / name).symlink_to(Path("Versions/Current") / name)
    write(contents / "Frameworks/Darkbloom Helper.app/Contents/MacOS/Darkbloom Helper")
    write(contents / "Frameworks/Darkbloom Helper (GPU).app/Contents/MacOS/Darkbloom Helper (GPU)")
    squirrel = contents / "Frameworks/Squirrel.framework"
    write(squirrel / "Versions/A/Squirrel")
    write(squirrel / "Versions/A/Resources/ShipIt")
    (squirrel / "Versions/Current").symlink_to("A")
    return app


class SignerTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.app = synthetic_app(self.root)
        (self.root / "bin").mkdir()
        stub = self.root / "bin/codesign"
        stub.write_text(CODESIGN)
        stub.chmod(0o755)
        self.log = self.root / "codesign.log"
        self.keychain = self.root / "signing.keychain-db"

    def sign(self, app=None, entitlements=ENTITLEMENTS, **env):
        return subprocess.run(
            [sys.executable, str(SCRIPT), str(app or self.app), "--identity", IDENTITY,
             "--keychain", str(self.keychain), "--entitlements", str(entitlements)],
            env={"PATH": f"{self.root / 'bin'}:/usr/bin:/bin", "STUB_LOG": str(self.log), **env},
            capture_output=True, text=True)

    def calls(self):
        return self.log.read_text().splitlines() if self.log.exists() else []

    def relative(self, path):
        return str(path.relative_to(self.app))

    def test_every_macho_file_and_nested_bundle_is_signed_inside_out(self):
        order = [self.relative(path) for path in SIGNER.signing_order(self.app)]
        framework = "Contents/Frameworks/Electron Framework.framework"
        self.assertEqual(sorted(order), sorted([
            ".", "Contents/MacOS/Darkbloom",
            framework, framework + "/Versions/A/Electron Framework",
            framework + "/Versions/A/Libraries/libEGL.dylib", framework + "/Versions/A/Helpers/chrome_crashpad_handler",
            "Contents/Frameworks/Darkbloom Helper.app", "Contents/Frameworks/Darkbloom Helper.app/Contents/MacOS/Darkbloom Helper",
            "Contents/Frameworks/Darkbloom Helper (GPU).app",
            "Contents/Frameworks/Darkbloom Helper (GPU).app/Contents/MacOS/Darkbloom Helper (GPU)",
            "Contents/Frameworks/Squirrel.framework", "Contents/Frameworks/Squirrel.framework/Versions/A/Squirrel",
            "Contents/Frameworks/Squirrel.framework/Versions/A/Resources/ShipIt"]))
        # The app is last, and every bundle comes after everything inside it.
        self.assertEqual(order[-1], ".")
        for index, path in enumerate(order[:-1]):
            inside = [other for other in order[:-1] if other.startswith(path + "/")]
            for other in inside:
                self.assertLess(order.index(other), index, (other, path))
        # Deepest first, and the same order on every run.
        depths = [len(Path(path).parts) for path in order[:-1]]
        self.assertEqual(depths, sorted(depths, reverse=True))
        self.assertEqual(order, [self.relative(path) for path in SIGNER.signing_order(self.app)])

    def test_links_and_files_that_are_not_code_are_left_alone(self):
        order = [self.relative(path) for path in SIGNER.signing_order(self.app)]
        for path in order:
            self.assertNotIn("Versions/Current", path)
            self.assertFalse((self.app / path).is_symlink(), path)
        for resource in ("app.asar", "icon.icns", "install-runtime.sh", "resources.pak", "Info.plist"):
            self.assertFalse(any(path.endswith(resource) for path in order), resource)
        # A link to code outside the app is not followed either.
        outside = self.root / "outside"
        write(outside / "tool")
        (self.app / "Contents/Resources/tool").symlink_to(outside / "tool")
        (self.app / "Contents/Resources/linked").symlink_to(outside)
        self.assertEqual(order, [self.relative(path) for path in SIGNER.signing_order(self.app)])

    def test_each_path_gets_the_release_options_and_the_app_is_verified_last(self):
        result = self.sign()
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls()
        order = SIGNER.signing_order(self.app)
        options = (f"--sign {IDENTITY} --force --keychain {self.keychain} --timestamp --options runtime "
                   f"--entitlements {ENTITLEMENTS} ")
        self.assertEqual(calls[:-1], [options + str(path) for path in order])
        self.assertEqual(calls[-1], f"--verify --deep --strict --verbose=2 {self.app}")

    def test_a_failed_signature_stops_before_anything_else_is_signed_or_verified(self):
        order = SIGNER.signing_order(self.app)
        result = self.sign(STUB_FAIL_ON=str(order[2]))
        self.assertNotEqual(result.returncode, 0)
        calls = self.calls()
        self.assertEqual(len(calls), 3)
        self.assertFalse(any(call.startswith("--verify") for call in calls))

    def test_refuses_anything_but_a_real_app_bundle_and_real_entitlements(self):
        link = self.root / "Link.app"
        link.symlink_to(self.app)
        plain = self.root / "Darkbloom"
        (plain / "Contents").mkdir(parents=True)
        for app in (link, plain, self.root / "Missing.app"):
            with self.subTest(app=app.name):
                result = self.sign(app=app)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Not an app bundle", result.stderr)
        result = self.sign(entitlements=self.root / "missing.plist")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Missing entitlements", result.stderr)
        self.assertEqual(self.calls(), [])

    def test_the_release_entitlements_are_the_three_electron_needs(self):
        with ENTITLEMENTS.open("rb") as stream:
            self.assertEqual(plistlib.load(stream), {
                "com.apple.security.cs.allow-jit": True,
                "com.apple.security.cs.allow-unsigned-executable-memory": True,
                "com.apple.security.cs.disable-library-validation": True})


def code_signature(path):
    """What codesign reports for one signed path, without the path itself."""
    described = subprocess.run(["codesign", "-d", "--verbose=4", str(path)], capture_output=True, text=True, check=True)
    fields = sorted(line for line in described.stderr.splitlines()
                    if line.startswith(("Identifier=", "CodeDirectory ", "CDHash=", "Signature=", "Sealed Resources",
                                        "Info.plist", "Runtime Version=")))
    entitlements = subprocess.run(["codesign", "-d", "--entitlements", "-", "--xml", str(path)],
                                  capture_output=True, check=True).stdout
    return fields, entitlements


@unittest.skipUnless(sys.platform == "darwin" and UNSIGNED_APP and NODE_MODULES.is_dir(),
                     "needs macOS, DARKBLOOM_DESKTOP_UNSIGNED_APP and desktop-app/node_modules")
class BuilderParityTests(unittest.TestCase):
    def test_the_signer_and_electron_builder_produce_the_same_code_signature(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            native, builder = root / "native/Darkbloom.app", root / "builder/Darkbloom.app"
            for copy in (native, builder):
                copy.parent.mkdir()
                subprocess.run(["ditto", UNSIGNED_APP, str(copy)], check=True)
            subprocess.run([sys.executable, str(SCRIPT), str(native), "--identity", "-",
                            "--keychain", str(root / "unused.keychain-db"), "--entitlements", str(ENTITLEMENTS)],
                           check=True, capture_output=True)
            subprocess.run(["node", "-e", OSX_SIGN, str(builder), str(ENTITLEMENTS)],
                           cwd=ROOT / "desktop-app", check=True, capture_output=True)
            subprocess.run(["codesign", "--verify", "--deep", "--strict", str(builder)], check=True)
            order = SIGNER.signing_order(native)
            # A real Electron app: the main executable, its four helpers and frameworks.
            self.assertGreaterEqual(len(order), 15)
            for path in order:
                relative = path.relative_to(native)
                with self.subTest(path=str(relative)):
                    self.assertEqual(code_signature(path), code_signature(builder / relative))
            # Nothing electron-builder's signer reaches is missing from the signer's order.
            signed = set(order)
            for directory, _, files in os.walk(native / "Contents"):
                for name in files:
                    path = Path(directory) / name
                    if not path.is_symlink() and SIGNER.is_macho(path):
                        self.assertIn(path, signed)


if __name__ == "__main__":
    unittest.main()
