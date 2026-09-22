"""Exercise tooling bootstrap reuse and failure handling without network access."""

import json
import os
from pathlib import Path
import shutil
import shlex
import subprocess
import sys
import tempfile
import unittest
import zipfile


MAKEFILE = Path(__file__).resolve().parents[1] / "Makefile"


class ToolingEnvironmentTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        shutil.copy2(MAKEFILE, self.root / "Makefile")
        self.toolchain = self.root / "mise.toml"
        self.toolchain.write_text('[tools]\npython = "3.12"\n')
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
    directory = Path(args[-1])
    if "--clear" in args and directory.exists():
        shutil.rmtree(directory)
    interpreter = directory / "bin/python"
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
        os.utime(self.toolchain, (0, 0))
        os.utime(stamp, (1, 1))
        self.requirements.write_text("numpy==2.4.2\n# revised input\n")
        result = self.make("tooling-install")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sum(call.startswith("-m pip install -r ") for call in self.calls()), 2)

    def change_python_pin(self, stamp):
        # Only the toolchain input is newer than the successful install. Keep
        # requirements older so they cannot accidentally trigger this rebuild.
        os.utime(self.requirements, (1, 1))
        os.utime(stamp, (2, 2))
        self.toolchain.write_text('[tools]\npython = "3.13"\n')
        os.utime(self.toolchain, (3, 3))

    def test_python_pin_change_rebuilds_and_then_reuses_environment(self):
        for directory in (".venv/tooling", ".venv/tooling-override"):
            with self.subTest(directory=directory):
                self.toolchain.write_text('[tools]\npython = "3.12"\n')
                result = self.make("tooling-install", TOOLING_VENV=directory)
                self.assertEqual(result.returncode, 0, result.stderr)
                stamp = self.root / directory / ".requirements-installed"
                old_environment_file = self.root / directory / "old-interpreter-state"
                old_environment_file.write_text("must disappear when the pin changes")
                previous = self.calls()
                requirements = self.requirements.read_bytes()
                self.change_python_pin(stamp)
                result = self.make("tooling-install", TOOLING_VENV=directory)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertFalse(old_environment_file.exists())
                self.assertEqual(self.requirements.read_bytes(), requirements)
                self.assertEqual(self.calls()[len(previous):], [
                    f'-m venv --clear {directory}',
                    '-m pip install -r scripts/benchmarks/attention_packet/requirements.txt',
                ])
                rebuilt = self.calls()
                result = self.make("tooling-install", TOOLING_VENV=directory)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.calls(), rebuilt)

    def test_failed_python_pin_refresh_blocks_tests_until_retry(self):
        result = self.make("tooling-install")
        self.assertEqual(result.returncode, 0, result.stderr)
        stamp = self.root / ".venv/tooling/.requirements-installed"
        self.change_python_pin(stamp)
        result = self.make(TOOLING_TEST_FAIL_INSTALL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(stamp.exists())
        self.assertFalse(any(call.startswith("-m unittest ") for call in self.calls()))
        result = self.make()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(stamp.is_file())
        self.assertEqual(sum(call.startswith("-m pip install -r ") for call in self.calls()), 3)
        self.assertEqual(sum(call.startswith("-m unittest ") for call in self.calls()), 3)

    def test_removed_requirement_is_absent_after_real_rebuild(self):
        # Exercise the real venv and pip commands with one tiny local wheel.
        # No package index or network access is needed for either install.
        # Ambient pip settings must not redirect installs outside this fixture.
        self.environment = {key: value for key, value in self.environment.items()
                            if not key.startswith("PIP_")}
        (self.bin / "python3").write_text(
            "#!/bin/sh\nexec " + shlex.quote(sys.executable) + ' "$@"\n')
        wheel = self.root / "tooling_removed_fixture-1.0-py3-none-any.whl"
        metadata = "tooling_removed_fixture-1.0.dist-info"
        files = {
            "tooling_removed_fixture.py": 'VALUE = "owned-local-wheel"\n',
            metadata + "/METADATA": "Metadata-Version: 2.1\nName: tooling-removed-fixture\nVersion: 1.0\n",
            metadata + "/WHEEL": "Wheel-Version: 1.0\nRoot-Is-Purelib: true\nTag: py3-none-any\n",
        }
        files[metadata + "/RECORD"] = "".join(name + ",,\n" for name in files) + metadata + "/RECORD,,\n"
        with zipfile.ZipFile(wheel, "w") as archive:
            for name, content in files.items():
                archive.writestr(name, content)
        self.requirements.write_text(str(wheel) + "\n")
        offline = {"PIP_CONFIG_FILE": os.devnull, "PIP_NO_INDEX": "1",
                   "PIP_DISABLE_PIP_VERSION_CHECK": "1"}
        result = self.make("tooling-install", **offline)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        interpreter = self.root / ".venv/tooling/bin/python"
        probe = '''\
import importlib.metadata
import importlib.util
import json

present = importlib.util.find_spec("tooling_removed_fixture") is not None
if present:
    import tooling_removed_fixture
    assert tooling_removed_fixture.VALUE == "owned-local-wheel"
try:
    version = importlib.metadata.version("tooling-removed-fixture")
except importlib.metadata.PackageNotFoundError:
    version = None
print(json.dumps({"importable": present, "version": version}))
'''

        def installed_state():
            observed = subprocess.run(
                [str(interpreter), "-I", "-c", probe],
                capture_output=True, text=True, timeout=30,
            )
            self.assertEqual(observed.returncode, 0, observed.stdout + observed.stderr)
            return json.loads(observed.stdout)

        self.assertEqual(installed_state(), {"importable": True, "version": "1.0"})
        # Removing a requirement must also remove its installed package and
        # metadata, exactly as a fresh developer/CI environment would see it.
        self.requirements.write_text("")
        os.utime(self.toolchain, (0, 0))
        os.utime(self.root / ".venv/tooling/.requirements-installed", (1, 1))
        result = self.make("tooling-install", **offline)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(installed_state(), {"importable": False, "version": None})

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
