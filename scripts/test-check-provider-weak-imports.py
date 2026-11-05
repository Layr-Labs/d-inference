#!/usr/bin/env python3
"""The binary check refuses the Date operators that a served macOS 27.2 lacks."""
import importlib.util
import io
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
_SPEC = importlib.util.spec_from_file_location("weak_imports", ROOT / "scripts/check-provider-weak-imports.py")
weak_imports = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(weak_imports)

GE = "_$s10Foundation4DateV2geoiySbAC_ACtFZ"
LE = "_$s10Foundation4DateV2leoiySbAC_ACtFZ"
# Lines of `nm -m` and `otool -tV` from DevNet build 0.10.6-dev.branch.87, the
# SDK 27.2 build that crashed on macOS 27.2 26B5091g.
NM_BRANCH_87 = f"""\
0000000103a57ab0 (__TEXT,__const) non-external (was a private external) _$s10Foundation3URLV11profilePath_Sb15alreadyEnrolledtMR
                 (undefined) weak external _$s10Foundation3URLV8filePath13directoryHint10relativeToACSS_AC09DirectoryF0OACSgtcfC (from Foundation)
                 (undefined) weak external {GE} (from Foundation)
                 (undefined) weak external {LE} (from Foundation)
                 (undefined) external _$s10Foundation10CocoaErrorV03_nsC0So7NSErrorCvg (from Foundation)
"""
NM_SDK_27_0 = """\
                 (undefined) weak external _$s10Foundation3URLV8filePath13directoryHint10relativeToACSS_AC09DirectoryF0OACSgtcfC (from Foundation)
                 (undefined) external _$s10Foundation10CocoaErrorV03_nsC0So7NSErrorCvg (from Foundation)
"""
OTOOL_BRANCH_87 = f"""\
/tmp/darkbloom-dev:
(__TEXT,__text) section
_$s12ProviderCore15ShadowKeyRecordV14mayGenerateKey2atSb10Foundation4DateV_tF:
00000001024f66a8\tldur\tx0, [x29, #-0x68]
00000001024f66b0\tbl\t0x1038b41ac ; symbol stub for: {GE}
00000001024f66c0\tbl\t0x1038b41ac ; symbol stub for: {GE}
_$s12ProviderCore8ScheduleV8isActive2at8calendarSb10Foundation4DateV_AF8CalendarVtF:
00000001024a33b4\tbl\t0x1038b41b8 ; symbol stub for: {LE}
_$s12ProviderCore8ScheduleV11isActiveNowSbyF:
00000001024a3400\tbl\t0x1024a33a0 ; isActive
"""


class RefusedImportTests(unittest.TestCase):
    def test_finds_each_refused_import_once_and_ignores_other_weak_imports(self):
        self.assertEqual(weak_imports.refused_imports(NM_BRANCH_87 + NM_BRANCH_87), [GE, LE])

    def test_a_binary_built_with_sdk_27_0_imports_neither_operator(self):
        self.assertEqual(weak_imports.refused_imports(NM_SDK_27_0), [])

    def test_a_strong_import_is_refused_too(self):
        self.assertEqual(weak_imports.refused_imports(f"   (undefined) external {LE} (from Foundation)\n"), [LE])

    def test_a_defined_symbol_is_not_an_import(self):
        self.assertEqual(weak_imports.refused_imports(f"0000000100001000 (__TEXT,__text) external {GE}\n"), [])

    def test_names_each_calling_function_once(self):
        self.assertEqual(weak_imports.referencing_functions(OTOOL_BRANCH_87, [GE, LE]), [
            "_$s12ProviderCore15ShadowKeyRecordV14mayGenerateKey2atSb10Foundation4DateV_tF",
            "_$s12ProviderCore8ScheduleV8isActive2at8calendarSb10Foundation4DateV_AF8CalendarVtF",
        ])


class MainTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="weak imports ")
        self.addCleanup(temp.cleanup)
        self.binary = Path(temp.name) / "darkbloom"
        self.binary.write_bytes(b"\xcf\xfa\xed\xfe")

    def run_main(self, outputs):
        def tool(arguments):
            self.assertEqual(arguments[-1], str(self.binary))
            return outputs[arguments[0]]
        stdout, stderr = io.StringIO(), io.StringIO()
        with mock.patch.object(weak_imports, "run_tool", side_effect=tool), \
                mock.patch.object(weak_imports, "demangle", side_effect=lambda names: names), \
                redirect_stdout(stdout), redirect_stderr(stderr):
            code = weak_imports.main([str(self.binary)])
        return code, stdout.getvalue(), stderr.getvalue()

    def test_refuses_the_crashing_build_and_names_its_callers(self):
        code, _, errors = self.run_main({"nm": NM_BRANCH_87, "otool": OTOOL_BRANCH_87})
        self.assertEqual(code, 1)
        self.assertIn(f"imports {GE}, static Date.>=", errors)
        self.assertIn(f"imports {LE}, static Date.<=", errors)
        self.assertIn("called from _$s12ProviderCore15ShadowKeyRecordV14mayGenerateKey", errors)
        self.assertIn("a.timeIntervalSince(b) >= 0", errors)

    def test_accepts_a_binary_without_the_operators(self):
        code, out, errors = self.run_main({"nm": NM_SDK_27_0})
        self.assertEqual((code, errors), (0, ""))
        self.assertIn("no Foundation import that a served macOS lacks", out)

    def test_a_missing_binary_fails(self):
        missing = self.binary.with_name("absent")
        stderr = io.StringIO()
        with redirect_stderr(stderr), redirect_stdout(io.StringIO()):
            self.assertEqual(weak_imports.main([str(missing)]), 1)
        self.assertIn(f"{missing}: no such binary", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
