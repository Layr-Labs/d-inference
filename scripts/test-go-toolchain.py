#!/usr/bin/env python3
"""Regression coverage for the production Go builder/module mismatch."""

import importlib.util
from pathlib import Path
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("go_toolchain", ROOT / "scripts/check-go-toolchain.py")
GUARD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GUARD)


class GoToolchainTests(unittest.TestCase):
    def check(self, minimum="1.26.0", local="1.26.8", builder="1.26.8", digest="a" * 64):
        return GUARD.check(
            f"module example.test/coordinator\n\ngo {minimum}\n",
            f'[tools]\ngo = "{local}"\n',
            f"FROM golang:{builder}-alpine@sha256:{digest} AS builder\n",
        )

    def test_current_repository_passes_cli(self):
        subprocess.run([sys.executable, str(ROOT / "scripts/check-go-toolchain.py")], check=True)

    def test_previous_production_pins_fail(self):
        with self.assertRaisesRegex(ValueError, "exact digest-pinned"):
            self.check(local="1.25.7", builder="1.25")

    def test_matching_but_outdated_pins_fail(self):
        with self.assertRaisesRegex(ValueError, "older than go.mod"):
            self.check(local="1.25.12", builder="1.25.12")

    def test_patch_minimum_is_enforced(self):
        with self.assertRaisesRegex(ValueError, "older than go.mod"):
            self.check(minimum="1.26.9")

    def test_local_container_drift_fails(self):
        with self.assertRaisesRegex(ValueError, "must match"):
            self.check(local="1.26.0")

    def test_digest_is_required(self):
        with self.assertRaisesRegex(ValueError, "exact digest-pinned"):
            self.check(digest="")

    def test_newer_patch_and_numeric_order_pass(self):
        self.check()
        self.check(minimum="1.9.9", local="1.10.0", builder="1.10.0")

    def test_release_integrity_runs_guard_and_regressions(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        integrity = workflow.split("  release-integrity:\n", 1)[1].split("\n  docs:", 1)[0]
        self.assertIn("python3 scripts/check-go-toolchain.py", integrity)
        self.assertIn("python3 scripts/test-go-toolchain.py", integrity)


if __name__ == "__main__":
    unittest.main()
