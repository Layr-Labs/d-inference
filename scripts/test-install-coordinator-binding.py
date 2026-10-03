#!/usr/bin/env python3
"""Run the installer's coordinator binding against temporary provider.toml files."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

INSTALLER = Path(__file__).resolve().parent / "install.sh"
DEV = "https://api.dev.darkbloom.xyz"
DEV_WS = 'url = "wss://api.dev.darkbloom.xyz/ws/provider"'


class CoordinatorBindingTests(unittest.TestCase):
    def bind(self, coordinator, existing=None):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / ".config" / "darkbloom" / "provider.toml"
            if existing is not None:
                config.parent.mkdir(parents=True)
                config.write_text(existing)
            result = subprocess.run(
                ["bash", str(INSTALLER), "--bind-coordinator-test", str(config)],
                env={**os.environ, "COORD_URL": coordinator}, capture_output=True, text=True)
            leftovers = sorted(p.name for p in config.parent.glob("*")) if config.parent.exists() else []
            return result, config.read_text() if config.exists() else None, leftovers

    def test_production_leaves_config_untouched(self):
        for existing in (None, '[coordinator]\nurl = "wss://other.invalid/ws/provider"\n'):
            for url in ("https://api.darkbloom.dev", "https://api.darkbloom.dev/"):
                with self.subTest(existing=existing, url=url):
                    result, text, _ = self.bind(url, existing)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(text, existing)

    def test_missing_config_is_created_with_only_the_coordinator(self):
        result, text, leftovers = self.bind(DEV + "/")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(text, "[coordinator]\n" + DEV_WS + "\n")
        self.assertEqual(leftovers, ["provider.toml"])
        self.assertIn("wss://api.dev.darkbloom.xyz/ws/provider", result.stdout)

    def test_existing_url_is_replaced_and_other_settings_are_kept(self):
        existing = (
            '[provider]\nname = "mac"\nauto_update = false\n\n'
            '[coordinator]\nheartbeat_interval_secs = 5\nprivate_only = true\n'
            'url = "wss://api.darkbloom.dev/ws/provider"\n\n'
            '[backend]\nenabled_models = ["a", "b"]\n')
        result, text, _ = self.bind(DEV, existing)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(text, existing.replace(
            'url = "wss://api.darkbloom.dev/ws/provider"', DEV_WS))

    def test_coordinator_section_without_url_gains_one(self):
        existing = '[coordinator]\nprivate_only = true\n\n[backend]\nport = 8100\n'
        result, text, _ = self.bind(DEV, existing)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            text, '[coordinator]\nprivate_only = true\n\n' + DEV_WS + '\n[backend]\nport = 8100\n')

    def test_config_without_coordinator_section_gains_one(self):
        for existing in ('[provider]\nname = "mac"\n', '[provider]\nname = "mac"'):
            with self.subTest(existing=existing):
                result, text, _ = self.bind(DEV, existing)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue(text.startswith('[provider]\nname = "mac"\n'))
                self.assertTrue(text.endswith("\n[coordinator]\n" + DEV_WS + "\n"))
                self.assertEqual(text.count("[coordinator]"), 1)

    def test_url_keys_in_other_tables_are_not_changed(self):
        existing = ('[coordinator.extra]\nurl = "keep-1"\n[coordinator]\nurl = "old"\n'
                    '[provider]\nurl = "keep-2"\n')
        result, text, _ = self.bind(DEV, existing)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(text, existing.replace('url = "old"', DEV_WS))

    def test_local_http_coordinator_uses_plain_websocket(self):
        for host in ("127.0.0.1:8080", "localhost"):
            with self.subTest(host=host):
                result, text, _ = self.bind("http://" + host)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(text, '[coordinator]\nurl = "ws://%s/ws/provider"\n' % host)

    def test_unsupported_url_fails_without_writing(self):
        for url in ("__DARKBLOOM_COORD_URL__", "ftp://x.invalid", "https://",
                    "http://192.0.2.10:8080", "http://dev.example.invalid",
                    "https://dev.example.invalid/prefix",
                    'https://dev.example.invalid"\n[provider]\nname = "x',
                    "https://dev.example.invalid\\n", "https://user@dev.example.invalid"):
            with self.subTest(url=url):
                result, text, _ = self.bind(url, "[provider]\n")
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(text, "[provider]\n")


if __name__ == "__main__":
    unittest.main()
