"""Inject local rename failures without downloading or running an installer."""

import json
import os
import shutil
from pathlib import Path
import subprocess
import tempfile
import unittest


INSTALLER = Path(__file__).resolve().with_name("install.sh")


class InstallerRollbackTests(unittest.TestCase):
    def test_failed_download_uses_private_temporary_files_and_cleans_them(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            log = root / "downloads.jsonl"
            curl = root / "curl"
            curl.write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
path = Path(sys.argv[sys.argv.index("-o") + 1])
root = Path(os.environ["TMPDIR"])
# Refuse to write outside the fixture, including an old shared /tmp path.
if path.parent != root:
    sys.exit(78)
with (root / "downloads.jsonl").open("a") as log:
    log.write(json.dumps({"path": str(path), "mode": path.stat().st_mode & 0o777}) + "\\n")
path.write_text("partial download")
sys.exit(22)
''')
            curl.chmod(0o755)
            source = INSTALLER.read_text()
            phase = source[source.index("TARBALL="):source.index("# Make available in PATH.")]
            for _ in range(2):
                result = subprocess.run(["bash", "-euc", phase], capture_output=True, text=True,
                                        env={**os.environ, "PATH": str(root) + os.pathsep + os.environ["PATH"],
                                             "TMPDIR": directory, "BUNDLE_URL": "fixture-only"})
                self.assertEqual(result.returncode, 22, result.stderr)
            attempts = [json.loads(line) for line in log.read_text().splitlines()]
            self.assertEqual(len({item["path"] for item in attempts}), 2)
            self.assertTrue(all(item["mode"] == 0o600 for item in attempts))
            self.assertTrue(all(not Path(item["path"]).exists() for item in attempts))

    def run_failed_swap(self, kind, fail_restore):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        root = Path(directory.name)
        installed = root / "installed"
        name = "Darkbloom.app" if kind == "app" else "bin"
        previous = installed / name
        previous.mkdir(parents=True)
        (previous / "original").write_text("previous verified payload")
        staged = root / "staged"
        staged.mkdir()
        (staged / "candidate").write_text("candidate payload")
        payload = staged / "Contents" / "MacOS" if kind == "app" else staged
        payload.mkdir(parents=True, exist_ok=True)
        for binary in ("darkbloom", "darkbloom-enclave"):
            (payload / binary).write_text("fixture binary")
        commands = root / "commands"
        commands.mkdir()
        mv = commands / "mv"
        mv.write_text('''#!/usr/bin/env python3
import os, subprocess, sys
from pathlib import Path
counter = Path(os.environ["INSTALL_TEST_MOVES"])
call = int(counter.read_text()) + 1 if counter.exists() else 1
counter.write_text(str(call))
if call == 2 or (call == 3 and os.environ["INSTALL_TEST_RESTORE_FAIL"] == "1"):
    sys.exit(1)
sys.exit(subprocess.run(["/bin/mv", *sys.argv[1:]]).returncode)
''')
        mv.chmod(0o755)
        # Only source function definitions. Platform checks, downloads, signing,
        # shell configuration, enrollment and service operations never execute.
        functions = INSTALLER.read_text().split(
            'if [ "${1:-}" = "--verify-staged-app-signature-test" ]; then', 1
        )[0]
        function = "commit_staged_app" if kind == "app" else "commit_staged_flat_bundle"
        result = subprocess.run(
            ["bash", "-c", functions + '\n' + function + ' "$1" "$2"',
             "fixture", str(staged), str(installed)],
            env={**os.environ, "PATH": str(commands) + os.pathsep + os.environ["PATH"],
                 "INSTALL_TEST_MOVES": str(root / "moves"),
                 "INSTALL_TEST_RESTORE_FAIL": "1" if fail_restore else "0"},
            capture_output=True, text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((staged / "candidate").read_text(), "candidate payload")
        return installed, name, result

    def test_failed_swap_restores_previous_install_and_cleans_backup(self):
        for kind in ("app", "flat"):
            with self.subTest(kind=kind):
                installed, name, _ = self.run_failed_swap(kind, fail_restore=False)
                self.assertEqual((installed / name / "original").read_text(),
                                 "previous verified payload")
                self.assertEqual(list(installed.glob(".install-backup-*")), [])

    def test_failed_rollback_preserves_backup_and_reports_recovery_path(self):
        for kind in ("app", "flat"):
            with self.subTest(kind=kind):
                installed, name, result = self.run_failed_swap(kind, fail_restore=True)
                backups = list(installed.glob(".install-backup-*"))
                self.assertEqual(len(backups), 1, "failed rollback must retain the only old copy")
                original = backups[0] / name
                self.assertEqual((original / "original").read_text(), "previous verified payload")
                self.assertIn(str(original), result.stderr)


def snapshot(path):
    """Capture contents, modes and link text without following symlinks."""
    if path.is_symlink():
        return ("link", path.lstat().st_mode & 0o777, os.readlink(path))
    if path.is_dir():
        return ("directory", path.stat().st_mode & 0o777,
                {child.name: snapshot(child) for child in path.iterdir()})
    if path.exists():
        return ("file", path.stat().st_mode & 0o777, path.read_bytes())
    return None


class InstallerCommitTests(unittest.TestCase):
    def fixture(self, kind, failures=None, previous_kind="directory"):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        root = Path(directory.name)
        installed = root / "installed"
        installed.mkdir()
        for name in ("Darkbloom.app", "bin"):
            path = installed / name
            path.mkdir()
            (path / "original").write_text("previous " + name)
        old_bin = installed / "bin"
        for name in ("darkbloom", "darkbloom-enclave", "mlx.metallib"):
            (old_bin / name).write_text("old " + name)
        (old_bin / "eigeninference-enclave").symlink_to("darkbloom-enclave")
        (old_bin / ".user-file").write_text("unrelated hidden file")
        (old_bin / "user-link").symlink_to("missing-user-target")
        (old_bin / "user-directory").mkdir()
        (old_bin / "user-directory" / "file").write_text("unrelated directory")
        name = "Darkbloom.app" if kind == "app" else "bin"
        if previous_kind == "absent":
            for path in installed.iterdir():
                shutil.rmtree(path)
        elif previous_kind != "directory":
            target = installed / ("previous-" + name)
            (installed / name).rename(target)
            (installed / name).symlink_to(
                target.name if previous_kind == "relative" else "missing-install-target")
        staged = root / "staged"
        payload = staged / "Contents" / "MacOS" if kind == "app" else staged
        payload.mkdir(parents=True)
        for binary in ("darkbloom", "darkbloom-enclave", "mlx.metallib"):
            (payload / binary).write_text("new " + binary)
        before = snapshot(installed)
        commands = root / "commands"
        commands.mkdir()
        for tool in ("mv", "ln", "chmod", "cp", "rm"):
            shim = commands / tool
            shim.write_text('''#!/usr/bin/env python3
import json, os, subprocess, sys
from pathlib import Path
tool = Path(sys.argv[0]).name
counter = Path(os.environ["INSTALL_TEST_ROOT"]) / (tool + "-calls")
call = int(counter.read_text()) + 1 if counter.exists() else 1
counter.write_text(str(call))
if call in json.loads(os.environ["INSTALL_TEST_FAILURES"]).get(tool, []):
    sys.exit(73)
sys.exit(subprocess.run(["/bin/" + tool, *sys.argv[1:]]).returncode)
''')
            shim.chmod(0o755)
        functions = INSTALLER.read_text().split(
            'if [ "${1:-}" = "--verify-staged-app-signature-test" ]; then', 1)[0]
        function = "commit_staged_app" if kind == "app" else "commit_staged_flat_bundle"
        result = subprocess.run(
            ["bash", "-c", functions + '\nif ' + function +
             ' "$1" "$2"; then exit 0; else exit 1; fi',
             "fixture", str(staged), str(installed)],
            env={**os.environ, "PATH": str(commands) + os.pathsep + os.environ["PATH"],
                 "INSTALL_TEST_ROOT": str(root),
                 "INSTALL_TEST_FAILURES": json.dumps(failures or {})},
            capture_output=True, text=True)
        return installed, before, result

    def test_preparation_failures_leave_both_live_paths_exactly_unchanged(self):
        for kind in ("app", "flat"):
            failures = [("chmod", 1), ("cp", 1)]
            failures += [("ln", n) for n in range(1, 5 if kind == "app" else 2)]
            for tool, call in failures:
                with self.subTest(kind=kind, tool=tool, call=call):
                    installed, before, result = self.fixture(kind, {tool: [call]})
                    self.assertNotEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(snapshot(installed), before)

    def test_every_commit_rename_failure_restores_both_paths(self):
        for kind in ("app", "flat"):
            for call in range(1, 5 if kind == "app" else 3):
                with self.subTest(kind=kind, call=call):
                    installed, before, result = self.fixture(kind, {"mv": [call]})
                    self.assertNotEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(snapshot(installed), before)

    def test_symlink_installations_survive_failed_swap_or_failed_restore(self):
        for kind in ("app", "flat"):
            for previous in ("relative", "dangling"):
                for fail_restore in (False, True):
                    with self.subTest(kind=kind, previous=previous, restore=fail_restore):
                        installed, before, result = self.fixture(
                            kind, {"mv": [2, 3] if fail_restore else [2]}, previous)
                        self.assertNotEqual(result.returncode, 0, result.stderr)
                        if not fail_restore:
                            self.assertEqual(snapshot(installed), before)
                            continue
                        backups = list(installed.glob(".install-backup-*"))
                        self.assertEqual(len(backups), 1)
                        name = "Darkbloom.app" if kind == "app" else "bin"
                        retained = backups[0] / name
                        self.assertEqual(snapshot(retained), before[2][name])
                        self.assertIn(str(retained), result.stderr)

    def test_app_bin_swap_failure_attempts_both_rollbacks_and_retains_failed_one(self):
        for restore_call, retained_name, restored_name in ((5, "bin", "Darkbloom.app"),
                                                          (6, "Darkbloom.app", "bin")):
            with self.subTest(restore_call=restore_call):
                installed, before, result = self.fixture("app", {"mv": [4, restore_call]})
                self.assertNotEqual(result.returncode, 0, result.stderr)
                backups = list(installed.glob(".install-backup-*"))
                self.assertEqual(len(backups), 1)
                retained = backups[0] / retained_name
                self.assertEqual(snapshot(retained), before[2][retained_name])
                self.assertEqual(snapshot(installed / restored_name), before[2][restored_name])
                self.assertIn(str(retained), result.stderr)

    def test_failed_candidate_removal_keeps_old_app_backup_and_restores_bin(self):
        installed, before, result = self.fixture("app", {"mv": [4], "rm": [1]})
        self.assertNotEqual(result.returncode, 0, result.stderr)
        backups = list(installed.glob(".install-backup-*"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(snapshot(backups[0] / "Darkbloom.app"), before[2]["Darkbloom.app"])
        self.assertEqual(snapshot(installed / "bin"), before[2]["bin"])
        self.assertIn(str(backups[0]), result.stderr)

    def test_first_install_success_and_failed_moves(self):
        for kind in ("app", "flat"):
            for call in range(0, 3 if kind == "app" else 2):
                with self.subTest(kind=kind, call=call):
                    installed, before, result = self.fixture(
                        kind, {"mv": [call]} if call else {}, previous_kind="absent")
                    if call:
                        self.assertNotEqual(result.returncode, 0, result.stderr)
                        self.assertEqual(snapshot(installed), before)
                    else:
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertEqual((installed / "bin" / "darkbloom").read_text(), "new darkbloom")
                        self.assertEqual(list(installed.glob(".install-*")), [])

    def test_success_installs_payload_and_preserves_unrelated_bin_entries(self):
        for kind in ("app", "flat"):
            with self.subTest(kind=kind):
                installed, before, result = self.fixture(kind)
                self.assertEqual(result.returncode, 0, result.stderr)
                for name in ("original", ".user-file", "user-link", "user-directory"):
                    self.assertEqual(snapshot(installed / "bin" / name), before[2]["bin"][2][name])
                self.assertEqual((installed / "bin" / "darkbloom").read_text(), "new darkbloom")
                self.assertTrue(os.access(installed / "bin" / "darkbloom", os.X_OK))
                self.assertEqual(os.readlink(installed / "bin" / "eigeninference-enclave"),
                                 "darkbloom-enclave")
                self.assertEqual(list(installed.glob(".install-*")), [])


if __name__ == "__main__":
    unittest.main()
