#!/usr/bin/env python3

import json
import os
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CHECK = ROOT / "scripts" / "docs-impact-check.py"


class DocsImpactCheckTests(unittest.TestCase):
    def run_check(self, *paths: str, labels: list[str] | None = None) -> subprocess.CompletedProcess[str]:
        command = ["python3", str(CHECK)]
        for path in paths:
            command.extend(["--changed-file", path])
        env = os.environ.copy()
        env["DOCS_IMPACT_LABELS"] = json.dumps(labels or [])
        return subprocess.run(command, cwd=ROOT, env=env, text=True, capture_output=True)

    def test_unrelated_source_change_passes(self) -> None:
        result = self.run_check("coordinator/api/example_telemetry_test.go")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_telemetry_change_requires_canonical_docs(self) -> None:
        result = self.run_check("coordinator/api/warm_pool_telemetry.go")
        self.assertEqual(result.returncode, 1)
        self.assertIn("telemetry source changed", result.stderr)
        self.assertIn("warm-pool and scheduling source changed", result.stderr)

    def test_each_matching_rule_must_be_satisfied(self) -> None:
        result = self.run_check(
            "coordinator/api/warm_pool_telemetry.go",
            "docs/reference/telemetry-inventory.md",
        )
        self.assertEqual(result.returncode, 1)
        self.assertNotIn("telemetry source changed", result.stderr)
        self.assertIn("warm-pool and scheduling source changed", result.stderr)

    def test_all_matching_docs_pass(self) -> None:
        result = self.run_check(
            "coordinator/api/warm_pool_telemetry.go",
            "docs/reference/telemetry-inventory.md",
            "docs/architecture/scheduling.md",
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_maintainer_override_passes(self) -> None:
        result = self.run_check(
            "coordinator/api/warm_pool_telemetry.go",
            labels=["docs-not-needed"],
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("bypassed", result.stdout)

    def test_reorganized_owners_keep_canonical_documentation_gates(self) -> None:
        cases = (
            ("coordinator/api/routes.go", "docs/reference/api-contracts.md"),
            ("coordinator/api/observation/events.go", "docs/architecture/telemetry.md"),
            ("coordinator/registry/admission/budget.go", "docs/architecture/routing.md"),
            ("coordinator/registry/selection/affinity.go", "docs/architecture/routing.md"),
            ("coordinator/app/startup_config.go", "docs/reference/configuration.md"),
            ("coordinator/store/postgres/migrations.go", "docs/architecture/storage.md"),
            ("coordinator/api/releases/policy.go", "docs/operations/provider-release.md"),
            ("coordinator/store/memory/memory.go", "docs/developer/navigation.md"),
            ("coordinator/app/app.go", "docs/developer/navigation.md"),
        )
        for source, document in cases:
            with self.subTest(source=source):
                missing = self.run_check(source)
                self.assertEqual(missing.returncode, 1, missing.stdout + missing.stderr)
                covered = self.run_check(source, document)
                self.assertEqual(covered.returncode, 0, covered.stdout + covered.stderr)

    def test_reorganized_private_tests_remain_excluded(self) -> None:
        result = self.run_check("coordinator/api/observation/owner_test.go",
                                "coordinator/store/postgres/migrations_test.go")
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
