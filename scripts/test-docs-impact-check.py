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


if __name__ == "__main__":
    unittest.main()
