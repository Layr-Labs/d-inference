#!/usr/bin/env python3
"""Exercise Metal registration recovery without running or installing Apple tools."""

import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).with_name("prepare-metal-toolchain.py")
SPEC = importlib.util.spec_from_file_location("prepare_metal", SCRIPT)
METAL = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(METAL)


class FakeAppleTools:
    def __init__(self, *, initially_ready=False, ready_at=None, ready_on_clear=False,
                 import_ready=False, export_names=("Metal.exportedBundle",), fail=None):
        self.now = 0.0
        self.ready = initially_ready
        self.ready_at = ready_at
        self.ready_on_clear = ready_on_clear
        self.import_ready = import_ready
        self.export_names = export_names
        self.fail = fail
        self.calls, self.sleeps, self.messages = [], [], []
        self.imported = None

    def clock(self):
        return self.now

    def sleep(self, seconds):
        self.sleeps.append(seconds)
        self.now += seconds

    def run(self, arguments, *, timeout, check, capture_output, text):
        self.calls.append((list(arguments), timeout))
        if self.fail == tuple(arguments):
            return subprocess.CompletedProcess(arguments, 1, "", "fixture command failure")
        if arguments == METAL.PROBE:
            ready = self.ready or (self.ready_at is not None and self.now >= self.ready_at)
            return subprocess.CompletedProcess(arguments, 0 if ready else 1,
                                               "metal version fixture" if ready else "",
                                               "" if ready else "missing Metal Toolchain")
        if arguments == ["xcrun", "--kill-cache"]:
            self.ready |= self.ready_on_clear
        if "-exportPath" in arguments:
            exported = Path(arguments[-1])
            if list(exported.iterdir()):
                raise AssertionError("Export destination was not fresh")
            for name in self.export_names:
                path = exported / name
                path.mkdir() if path.suffix == ".exportedBundle" else path.write_text("fixture DMG")
        if "-importPath" in arguments:
            self.imported = Path(arguments[-1])
            if not self.imported.exists():
                raise AssertionError("Import did not use the exact exported component")
            self.ready |= self.import_ready
        return subprocess.CompletedProcess(arguments, 0, "", "")


class MetalSetupTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="metal-setup-tests-")
        self.addCleanup(temporary.cleanup)
        self.temporary = Path(temporary.name)

    def setup_for(self, fake, **options):
        return METAL.MetalSetup(timeout=options.pop("timeout", 60),
                               registration=options.pop("registration", 10), poll=2,
                               run=fake.run, clock=fake.clock, sleep=fake.sleep,
                               log=fake.messages.append, temporary_root=self.temporary, **options)

    def test_ready_compiler_needs_no_download_or_wait(self):
        fake = FakeAppleTools(initially_ready=True)
        self.setup_for(fake).prepare()
        self.assertEqual([call[0] for call in fake.calls], [METAL.PROBE, ["xcrun", "--kill-cache"]])
        self.assertEqual(fake.sleeps, [])
        self.assertEqual(list(self.temporary.iterdir()), [])

    def test_download_then_asynchronous_registration_succeeds(self):
        fake = FakeAppleTools(ready_at=4)
        self.setup_for(fake).prepare()
        commands = [call[0] for call in fake.calls]
        self.assertIn(METAL.DOWNLOAD, commands)
        self.assertIn(["xcrun", "--kill-cache"], commands)
        self.assertEqual(fake.sleeps, [2, 2])
        self.assertFalse(any("-importPath" in command for command in commands))

    def test_cache_clear_and_uncached_probe_recover_negative_lookup(self):
        fake = FakeAppleTools(ready_on_clear=True)
        self.setup_for(fake).prepare()
        commands = [call[0] for call in fake.calls]
        self.assertEqual(commands, [METAL.PROBE, METAL.DOWNLOAD,
                                    ["xcrun", "--kill-cache"], METAL.PROBE])

    def test_export_import_accepts_one_bundle_or_one_top_level_dmg(self):
        for exported in ("Metal.exportedBundle", "Metal.dmg"):
            with self.subTest(exported=exported):
                fake = FakeAppleTools(import_ready=True, export_names=(exported,))
                self.setup_for(fake).prepare()
                self.assertEqual(fake.imported.name, exported)
                self.assertFalse(fake.imported.exists())
                self.assertEqual(list(self.temporary.iterdir()), [])
                self.assertEqual(fake.calls[-1][0], METAL.PROBE)
                self.assertEqual(sum(call[0] == ["xcrun", "--kill-cache"] for call in fake.calls), 2)

    def test_export_ambiguity_or_missing_bundle_fails_before_import(self):
        for exports in ((), ("one.dmg", "two.dmg"), ("Metal.exportedBundle", "Metal.dmg")):
            with self.subTest(exports=exports):
                fake = FakeAppleTools(import_ready=True, export_names=exports)
                with self.assertRaisesRegex(METAL.SetupError, "exactly one"):
                    self.setup_for(fake).prepare()
                self.assertIsNone(fake.imported)
                self.assertEqual(list(self.temporary.iterdir()), [])

    def test_successful_download_and_import_do_not_replace_compiler_probe(self):
        fake = FakeAppleTools()
        with self.assertRaisesRegex(METAL.SetupError, "remains unavailable.*missing Metal Toolchain"):
            self.setup_for(fake).prepare()
        self.assertIsNotNone(fake.imported)
        self.assertFalse(any("ready" in message for message in fake.messages))

    def test_failed_download_fails_without_claiming_installation(self):
        fake = FakeAppleTools(fail=tuple(METAL.DOWNLOAD))
        with self.assertRaisesRegex(METAL.SetupError, "command failed"):
            self.setup_for(fake).prepare()
        self.assertEqual(len(fake.calls), 2)
        self.assertEqual(fake.sleeps, [])

    def test_global_deadline_bounds_polling_and_every_subprocess(self):
        fake = FakeAppleTools()
        with self.assertRaisesRegex(METAL.SetupError, "deadline exceeded"):
            self.setup_for(fake, timeout=3, registration=10).prepare()
        self.assertEqual(fake.now, 3)
        self.assertEqual(fake.sleeps, [2, 1])
        self.assertTrue(all(0 < timeout <= 3 for _, timeout in fake.calls))
        self.assertIsNone(fake.imported)

    def test_subprocess_timeout_fails_closed(self):
        fake = FakeAppleTools()
        setup = self.setup_for(fake)

        def timeout(arguments, **kwargs):
            raise subprocess.TimeoutExpired(arguments, kwargs["timeout"])

        setup.run = timeout
        with self.assertRaisesRegex(METAL.SetupError, "command timed out"):
            setup.prepare()

    def test_symlinked_export_is_not_imported(self):
        outside = self.temporary / "outside.dmg"
        outside.write_text("unrelated")
        exported = self.temporary / "export"
        exported.mkdir()
        (exported / "Metal.dmg").symlink_to(outside)
        with self.assertRaisesRegex(METAL.SetupError, "unsafe"):
            METAL.exported_component(exported)
        self.assertEqual(outside.read_text(), "unrelated")

    def test_selected_xcode_and_sdk_environment_are_preserved(self):
        environment = {"DEVELOPER_DIR": "/selected/Xcode/Contents/Developer",
                       "PROVIDER_SDKROOT": "/selected/MacOSX27.0.sdk",
                       "PROVIDER_SWIFT": "/selected/usr/bin/swift"}
        with patch.dict(os.environ, environment):
            fake = FakeAppleTools(import_ready=True)
            self.setup_for(fake).prepare()
            self.assertEqual({name: os.environ[name] for name in environment}, environment)
            self.assertFalse(any("xcode-select" in command for command, _ in fake.calls))

    def test_nonfinite_or_nonpositive_limits_are_rejected(self):
        for value in (0, -1, float("inf"), float("nan")):
            with self.subTest(value=value), self.assertRaises(ValueError):
                METAL.MetalSetup(timeout=value)


if __name__ == "__main__":
    unittest.main()
