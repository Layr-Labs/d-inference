#!/usr/bin/env python3
"""Guard provider-owned documentation mappings without a private backend checkout."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]
CHECK = ROOT / "scripts/docs-impact-check.py"
spec = importlib.util.spec_from_file_location("docs_impact", CHECK)
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)
RULES = checker.load_rules(ROOT / "scripts/docs-impact-rules.json")


class DocsImpactCheckTests(unittest.TestCase):
    def test_ci_checks_pr_head_instead_of_synthetic_merge(self):
        workflow = (ROOT / ".github/workflows/docs-impact.yml").read_text()
        self.assertIn("          ref: ${{ github.event.pull_request.head.sha }}\n"
                      "          fetch-depth: 0\n", workflow)
        self.assertIn("DOCS_IMPACT_BASE: ${{ github.event.pull_request.base.sha }}", workflow)

    def test_provider_sensitive_rules_need_their_own_docs(self):
        cases = {
            "provider protocol": "provider-swift/Sources/ProviderCore/Protocol/Types.swift",
            "provider telemetry": "provider-swift/Sources/ProviderCore/Telemetry/TelemetryEvent.swift",
            "provider configuration": "provider-swift/Sources/ProviderCore/Config/ProviderConfig.swift",
            "native inference": "provider-swift/Sources/ProviderCore/Inference/Engine/InferenceFailure.swift",
            "provider memory and capacity": "provider-swift/Sources/ProviderCore/Inference/Memory/UnifiedMemoryCap.swift",
            "provider SSD prefix cache": "provider-swift/Sources/ProviderCore/KVCacheSSD/CacheStorage.swift",
            "cache storage privacy": "provider-swift/Sources/ProviderCore/KVCacheSSD/CacheStorage.swift",
            "provider privacy and trust": "provider-swift/Sources/ProviderCore/Crypto/NodeKeyPair.swift",
            "provider model manifests": "scripts/publish-model.sh",
            "provider release": "scripts/install.sh",
            "provider Autopilot": "provider-swift/Sources/ProviderCore/Autopilot/ModelAutopilotSettings.swift",
            "provider local API": "provider-swift/Sources/ProviderCore/Server/LocalServer.swift",
            "public fixtures and qualification": "provider-swift/Tests/ProviderCoreTests/Fixtures/Protocol/process_memory_wire.json",
            "build and test tooling": "scripts/docs-impact-rules.json",
            "landing": "landing/package.json",
            "repository ownership": "AGENTS.md",
        }
        self.assertEqual(set(cases), {rule["name"] for rule in RULES["rules"]})
        all_docs = {doc for rule in RULES["rules"] for doc in rule["docs_any_of"]}
        for rule in RULES["rules"]:
            source = cases[rule["name"]]
            with self.subTest(rule=rule["name"]):
                unrelated = all_docs - set(rule["docs_any_of"])
                violations = checker.violations(RULES, [source, *unrelated])
                self.assertIn(rule["name"], {item[0]["name"] for item in violations})
                for doc in rule["docs_any_of"]:
                    self.assertTrue((ROOT / doc).is_file(), doc)
                    covered = checker.violations(RULES, [source, *unrelated, doc])
                    self.assertNotIn(rule["name"], {item[0]["name"] for item in covered})

    def test_all_matching_rules_must_be_satisfied(self):
        source = "provider-swift/Sources/ProviderCore/KVCacheSSD/CacheStorage.swift"
        partial = checker.violations(RULES, [source, "docs/reference/ssd-kv-cache.md"])
        self.assertEqual({rule["name"] for rule, _ in partial}, {"cache storage privacy"})
        self.assertEqual(checker.violations(RULES, [source, "docs/reference/ssd-kv-cache.md",
                                                  "docs/provider/cache-storage.md"]), [])

    def test_swift_tests_are_ignored_but_public_fixtures_are_not(self):
        self.assertEqual(checker.violations(RULES, [
            "provider-swift/Tests/ProviderCoreTests/Protocol/ProtocolTests.swift"]), [])
        fixture = "provider-swift/Tests/ProviderCoreTests/Fixtures/Protocol/profiler_wire_fixture.json"
        violations = checker.violations(RULES, [fixture])
        self.assertEqual({rule["name"] for rule, _ in violations},
                         {"provider protocol", "public fixtures and qualification"})

    def test_retired_platform_mappings_are_not_local_ownership(self):
        for rule in RULES["rules"]:
            for pattern in rule["source_patterns"]:
                self.assertFalse(pattern.startswith(("coordinator/", "console-ui/", "admin-ui/", "e2e/")))
            for document in rule["docs_any_of"]:
                self.assertTrue((ROOT / document).is_file(), document)

    def test_cli_fails_closed_and_retains_explicit_maintainer_override(self):
        source = "provider-swift/Sources/ProviderCore/Protocol/Types.swift"
        command = ["python3", str(CHECK), "--changed-file", source]
        env = {**os.environ, "DOCS_IMPACT_LABELS": "[]"}
        missing = subprocess.run(command, cwd=ROOT, env=env, text=True, capture_output=True)
        self.assertEqual(missing.returncode, 1, missing.stdout + missing.stderr)
        self.assertIn("provider protocol source changed", missing.stderr)
        covered = subprocess.run(command + ["--changed-file", "docs/reference/protocol-messages.md"],
                                 cwd=ROOT, env=env, text=True, capture_output=True)
        self.assertEqual(covered.returncode, 0, covered.stdout + covered.stderr)
        env["DOCS_IMPACT_LABELS"] = json.dumps(["docs-not-needed"])
        overridden = subprocess.run(command, cwd=ROOT, env=env, text=True, capture_output=True)
        self.assertEqual(overridden.returncode, 0, overridden.stdout + overridden.stderr)
        self.assertIn("bypassed", overridden.stdout)


if __name__ == "__main__":
    unittest.main()
