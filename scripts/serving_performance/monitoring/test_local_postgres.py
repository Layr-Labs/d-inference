"""Portable discovery and failure cleanup for the disposable SQL fixture."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from .local_postgres import LocalPostgres, TOOLS, discover_postgres_binaries


class LocalPostgresTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def installation(self, directory, names=TOOLS):
        directory.mkdir(parents=True)
        for name in names:
            path = directory / name
            path.touch()
            path.chmod(0o700)
        return {name: str(directory / name) for name in TOOLS}

    def test_debian_installation_without_path_tools_uses_one_complete_version(self):
        self.installation(self.root / "9.6" / "bin")
        expected = self.installation(self.root / "16" / "bin")
        self.installation(self.root / "17" / "bin", names=("psql",))
        with patch("shutil.which", return_value=None):
            self.assertEqual(discover_postgres_binaries(self.root), expected)

    def test_pg_config_finds_a_nonstandard_complete_installation(self):
        expected = self.installation(self.root / "custom" / "bin")
        with patch("shutil.which", side_effect=lambda name: "/tools/pg_config" if name == "pg_config" else None), \
             patch("subprocess.run", return_value=subprocess.CompletedProcess(
                 [], 0, stdout=str(self.root / "custom" / "bin") + "\n")):
            self.assertEqual(discover_postgres_binaries(self.root), expected)

    def test_partial_startup_is_cleaned_and_reports_server_log_with_safe_locale(self):
        binaries = self.installation(self.root / "bin")
        calls = []

        def run(command, **kwargs):
            calls.append((command, kwargs))
            if command[0] == binaries["initdb"]:
                postgres.data.mkdir()
            elif command[-1] == "start":
                (postgres.data / "postmaster.pid").write_text("fixture-pid")
                postgres.log.write_text("postmaster startup diagnostic")
                raise subprocess.CalledProcessError(1, command, stderr="pg_ctl failed\n")
            return subprocess.CompletedProcess(command, 0, stdout="")

        with patch.dict(os.environ, LC_ALL="en_US.UTF-8"):
            postgres = LocalPostgres(binaries)
            self.addCleanup(postgres.close)
            with patch("subprocess.run", side_effect=run):
                with self.assertRaisesRegex(RuntimeError, "postmaster startup diagnostic"):
                    postgres.start()
                postgres.close()
            self.assertEqual(os.environ["LC_ALL"], "en_US.UTF-8")
        self.assertFalse(postgres.directory.exists())
        self.assertEqual(calls[-1][0][-1], "stop")
        self.assertTrue(all(kwargs["env"]["LC_ALL"] == "C" for _, kwargs in calls))
        server_options = calls[1][0][calls[1][0].index("-o") + 1]
        self.assertIn("-h ''", server_options)
        self.assertIn(f"-k {postgres.directory} -p {postgres.port}", server_options)
        self.assertEqual(postgres.client[postgres.client.index("-p") + 1], postgres.port)


if __name__ == "__main__":
    unittest.main()
