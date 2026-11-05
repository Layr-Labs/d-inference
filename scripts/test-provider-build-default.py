#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "provider-build-default.py"
SPEC = importlib.util.spec_from_file_location("provider_build_default", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def package(default):
    return (
        "// swift-tools-version: 6.1\n"
        "// DARKBLOOM_RELEASE_ENVIRONMENT selects the build environment.\n"
        'let releaseEnvironment = ProcessInfo.processInfo.environment["DARKBLOOM_RELEASE_ENVIRONMENT"]\n'
        '    .flatMap { $0.isEmpty ? nil : $0 } ?? "' + default + '"\n'
        'precondition(["prod", "dev", "staging"].contains(releaseEnvironment),\n'
        '             "DARKBLOOM_RELEASE_ENVIRONMENT must be prod, dev or staging")\n')


class ProviderBuildDefaultTests(unittest.TestCase):
    def test_master_requires_prod(self):
        self.assertIn("'prod'", MODULE.check("master", package("prod")))
        for default in ["dev", "staging", ""]:
            with self.subTest(default=default), self.assertRaisesRegex(ValueError, "requires the plain-build default 'prod'"):
                MODULE.check("master", package(default))

    def test_dev_requires_dev(self):
        self.assertIn("'dev'", MODULE.check("dev", package("dev")))
        for default in ["prod", "staging"]:
            with self.subTest(default=default), self.assertRaisesRegex(ValueError, "requires the plain-build default 'dev'"):
                MODULE.check("dev", package(default))

    def test_other_targets_are_not_checked(self):
        for branch in ["main", "feature/x", "masterx", ""]:
            with self.subTest(branch=branch):
                self.assertIn("no plain-build default is required", MODULE.check(branch, "no default here"))

    def test_a_missing_or_changed_default_line_fails(self):
        refactors = [
            "",
            'let releaseEnvironment = ProcessInfo.processInfo.environment["DARKBLOOM_RELEASE_ENVIRONMENT"] ?? "prod"\n',
            'let releaseEnvironment = ProcessInfo.processInfo.environment["DARKBLOOM_RELEASE_ENVIRONMENT"]\n'
            "    .flatMap { $0.isEmpty ? nil : $0 } ?? fallbackEnvironment\n",
            package("prod") + package("dev"),
        ]
        for text in refactors:
            for branch in ["master", "dev"]:
                with self.subTest(text=text, branch=branch), self.assertRaisesRegex(ValueError, "expected one plain-build default"):
                    MODULE.check(branch, text)

    def test_reads_this_checkout_package(self):
        self.assertIn(MODULE.plain_build_default(MODULE.PACKAGE.read_text(encoding="utf-8")),
                      ["prod", "dev", "staging"])

    def test_command_exit_status_and_message(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Package.swift"
            path.write_text(package("dev"), encoding="utf-8")
            run = lambda branch: subprocess.run(
                [sys.executable, str(SCRIPT), "--branch", branch, "--package", str(path)],
                capture_output=True, text=True)
            passed = run("dev")
            self.assertEqual(passed.returncode, 0, passed.stderr)
            self.assertIn("plain-build default is 'dev'", passed.stdout)
            failed = run("master")
            self.assertEqual(failed.returncode, 1)
            self.assertIn("requires the plain-build default 'prod'", failed.stderr)
            missing = subprocess.run(
                [sys.executable, str(SCRIPT), "--branch", "master", "--package", str(Path(directory) / "absent")],
                capture_output=True, text=True)
            self.assertEqual(missing.returncode, 1)
            self.assertIn("provider-build-default:", missing.stderr)

    def test_ci_checks_the_target_branch_in_release_integrity(self):
        # Release Integrity runs only in CI (master) (David, 2026-11-04).
        ci = (ROOT / ".github/workflows/ci-master.yml").read_text(encoding="utf-8")
        job = re.search(r"(?ms)^  release-integrity:\n(.*?)(?=^  [a-z][a-z0-9_-]*:\n)", ci).group(1)
        # Nothing but cancellation skips it: it waits only for the plan whose
        # route it reads.
        self.assertEqual(re.findall(r"(?m)^    if: (.+)$", job), ["${{ !cancelled() }}"])
        self.assertIn("TARGET_BRANCH: ${{ github.base_ref || github.ref_name }}", job)
        self.assertIn("python3 scripts/test-provider-build-default.py", job)
        self.assertIn('python3 scripts/provider-build-default.py --branch "$TARGET_BRANCH"', job)

    def test_master_release_lanes_check_before_build_and_signing(self):
        release = (ROOT / ".github/workflows/release-provider.yml").read_text(encoding="utf-8")
        resolve = release.split("\n  resolve-env:\n", 1)[1].split("\n  build-provider:\n", 1)[0]
        guard = resolve.split("- name: Check that master's plain build defaults to prod\n", 1)[1].split("\n      - ", 1)[0]
        self.assertIn("if: github.ref != 'refs/heads/dev'", guard)
        self.assertIn("run: python3 scripts/provider-build-default.py --branch master", guard)
        self.assertLess(resolve.index("ref: ${{ steps.trust.outputs.source_sha }}"),
                        resolve.index("provider-build-default.py"))
        self.assertLess(resolve.index("provider-build-default.py"),
                        resolve.index("./scripts/resolve-provider-release.sh"))


if __name__ == "__main__":
    unittest.main()
