#!/usr/bin/env python3
"""Exercise release routing before the workflow can access signing credentials."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class ReleaseResolutionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / "scripts").mkdir()
        for name in ("resolve-provider-release.sh", "check-release-version.sh"):
            shutil.copy2(Path(__file__).parent / name, self.root / "scripts" / name)
        for name, content in (
            ("provider-swift/Sources/ProviderCore/ProviderCore.swift", 'public static let version = "0.9.0"'),
            ("coordinator/api/server.go", 'var LatestProviderVersion = "0.9.0"'),
        ):
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content + "\n")

    def resolve(self, **overrides):
        output = self.root / "outputs"
        output.write_text("")
        env = {"PATH": os.environ["PATH"], "GITHUB_OUTPUT": str(output),
               "GITHUB_EVENT_NAME": "workflow_dispatch", "GITHUB_REF_TYPE": "branch",
               "GITHUB_REF_NAME": "candidate", "RELEASE_ENVIRONMENT": "dev"}
        env.update(overrides)
        result = subprocess.run(["bash", "scripts/resolve-provider-release.sh"], cwd=self.root,
                                env=env, capture_output=True, text=True, timeout=10)
        values = dict(line.split("=", 1) for line in output.read_text().splitlines())
        return result, values

    def test_manual_dev_release_and_signed_validation_have_distinct_destinations(self):
        for validation, publish in (("", "true"), ("false", "true"), ("true", "false")):
            with self.subTest(validation=validation):
                result, values = self.resolve(RELEASE_VALIDATION_ONLY=validation)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(values, {"environment": "dev", "version": "0.9.0", "publish": publish})

    def test_production_tags_and_legacy_swift_alias_keep_source_version(self):
        for tag in ("v0.9.0", "v0.9.0-swift", "v0.9.0-swift.1"):
            with self.subTest(tag=tag):
                result, values = self.resolve(GITHUB_EVENT_NAME="push", GITHUB_REF_TYPE="tag",
                                               GITHUB_REF_NAME=tag, RELEASE_ENVIRONMENT="")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(values, {"environment": "prod", "version": "0.9.0", "publish": "true"})

    def test_invalid_routes_emit_no_authorization_outputs(self):
        cases = [
            {"RELEASE_ENVIRONMENT": "prod"},
            {"RELEASE_ENVIRONMENT": "prod", "RELEASE_VALIDATION_ONLY": "true", "GITHUB_REF_TYPE": "tag"},
            {"RELEASE_VALIDATION_ONLY": "true", "GITHUB_EVENT_NAME": "push"},
            {"GITHUB_REF_TYPE": "tag", "GITHUB_REF_NAME": "v0.9.0-dev.1"},
            {"RELEASE_VERSION_OVERRIDE": "0.9.1"},
            {"RELEASE_ENVIRONMENT": "dev\npublish=true"},
            {"RELEASE_VALIDATION_ONLY": "1"},
            {"RELEASE_VERSION_OVERRIDE": "$(touch unexpected-command)"},
        ]
        for case in cases:
            with self.subTest(case=case):
                result, values = self.resolve(**case)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(values, {})
        self.assertFalse((self.root / "unexpected-command").exists())

    def test_validation_requires_matching_provider_and_coordinator_versions(self):
        (self.root / "coordinator/api/server.go").write_text('var LatestProviderVersion = "0.9.1"\n')
        result, values = self.resolve(RELEASE_VALIDATION_ONLY="true")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(values, {})


if __name__ == "__main__":
    unittest.main()
