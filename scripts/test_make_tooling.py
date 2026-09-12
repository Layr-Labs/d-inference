"""Exercise tooling bootstrap reuse and failure handling without network access."""

import os
from pathlib import Path
import shutil
import shlex
import subprocess
import sys
import tempfile
import unittest


MAKEFILE = Path(__file__).resolve().parents[1] / "Makefile"


class ToolingEnvironmentTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        shutil.copy2(MAKEFILE, self.root / "Makefile")
        self.requirements = self.root / "scripts/benchmarks/attention_packet/requirements.txt"
        self.requirements.parent.mkdir(parents=True)
        self.requirements.write_text("numpy==2.4.2\n")
        self.log = self.root / "calls.log"
        self.bin = self.root / "bin"
        self.bin.mkdir()
        fake_python = self.bin / "python3"
        fake_python.write_text(f"#!{sys.executable}\n" + '''\
import os
from pathlib import Path
import shutil
import sys

args = sys.argv[1:]
with open(os.environ["TOOLING_TEST_LOG"], "a") as log:
    log.write(" ".join(args) + "\\n")
if args[:2] == ["-m", "venv"]:
    interpreter = Path(args[2]) / "bin/python"
    interpreter.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(__file__, interpreter)
if args[:2] == ["-m", "pip"] and os.environ.get("TOOLING_TEST_FAIL_INSTALL"):
    sys.exit(17)
''')
        fake_python.chmod(0o755)
        # Each stub tree exercises its own Makefile defaults. An outer `make
        # tooling-test TOOLING_VENV=...` exports both recursive flags and values.
        inherited_make = {"MAKEFLAGS", "MAKEOVERRIDES", "MFLAGS", "GNUMAKEFLAGS", "MAKELEVEL",
                          "TOOLING_VENV", "TOOLING_PYTHON", "TOOLING_REQUIREMENTS"}
        self.environment = {
            **{key: value for key, value in os.environ.items() if key not in inherited_make},
            "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
            "TOOLING_TEST_LOG": str(self.log),
        }

    def make(self, target="tooling-test", **environment):
        return subprocess.run(
            ["make", target], cwd=self.root,
            env={**self.environment, **environment},
            capture_output=True, text=True,
        )

    def calls(self):
        return self.log.read_text().splitlines() if self.log.exists() else []

    def test_fresh_tests_install_once_and_reuse_pinned_environment(self):
        for _ in range(2):
            result = self.make()
            self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls()
        self.assertEqual(sum(call.startswith("-m venv ") for call in calls), 1)
        self.assertEqual(sum(call.startswith("-m pip install -r ") for call in calls), 1)
        self.assertEqual(sum(call.startswith("-m unittest ") for call in calls), 6)
        self.assertEqual(sum(call.startswith("scripts/test-provider-") for call in calls), 4)
        self.assertTrue((self.root / ".venv/tooling/.requirements-installed").is_file())

    def test_changed_requirement_refreshes_environment(self):
        self.assertEqual(self.make("tooling-install").returncode, 0)
        stamp = self.root / ".venv/tooling/.requirements-installed"
        # Make the prior successful install older than its dependency without sleeping.
        os.utime(stamp, (1, 1))
        self.requirements.write_text("numpy==2.4.2\n# revised input\n")
        result = self.make("tooling-install")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sum(call.startswith("-m pip install -r ") for call in self.calls()), 2)

    def test_failed_install_blocks_tests_and_is_retried(self):
        result = self.make(TOOLING_TEST_FAIL_INSTALL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / ".venv/tooling/.requirements-installed").exists())
        self.assertFalse(any(call.startswith("-m unittest ") for call in self.calls()))
        result = self.make()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sum(call.startswith("-m pip install -r ") for call in self.calls()), 2)

    def test_outer_make_override_does_not_change_stub_environment(self):
        outer = self.root / "outer.mk"
        test = "scripts.test_make_tooling.ToolingEnvironmentTests.test_fresh_tests_install_once_and_reuse_pinned_environment"
        outer.write_text(".PHONY: check\ncheck:\n\t" + shlex.quote(sys.executable)
                         + " -m unittest " + test + "\n")
        result = subprocess.run(
            ["make", "-f", str(outer), "check", "TOOLING_VENV=.venv/tooling-py312"],
            cwd=MAKEFILE.parent, capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
