"""Inject local rename failures without downloading or running an installer."""

import json
import os
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


if __name__ == "__main__":
    unittest.main()
