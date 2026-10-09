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

    def test_production_tag_keeps_source_version(self):
        result, values = self.resolve(GITHUB_EVENT_NAME="push", GITHUB_REF_TYPE="tag",
                                       GITHUB_REF_NAME="v0.9.0", RELEASE_ENVIRONMENT="")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(values, {"environment": "prod", "version": "0.9.0", "publish": "true"})

    def test_retired_swift_tag_alias_is_rejected(self):
        # `v*.*.*` still matches these tags, so resolution must refuse them.
        for tag in ("v0.9.0-swift", "v0.9.0-swift.1"):
            with self.subTest(tag=tag):
                result, values = self.resolve(GITHUB_EVENT_NAME="push", GITHUB_REF_TYPE="tag",
                                               GITHUB_REF_NAME=tag, RELEASE_ENVIRONMENT="")
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(values, {})

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

    def test_missing_malformed_or_ambiguous_provider_version_fails_before_outputs(self):
        source = self.root / "provider-swift/Sources/ProviderCore/ProviderCore.swift"
        for content in (None, "", 'public static let version = "invalid"',
                        'public static let version = "0.9.0"\npublic static let version = "0.9.0"'):
            with self.subTest(content=content):
                if content is None:
                    source.unlink()
                else:
                    source.write_text(content)
                result, values = self.resolve(RELEASE_VALIDATION_ONLY="true")
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(values, {})

    def test_binary_version_must_match_provider_source(self):
        for reported, accepted in (("darkbloom 0.9.0", True), ("0.9.0", True),
                                   ("darkbloom 0.9.1", False), ("garbage", False)):
            with self.subTest(reported=reported):
                result = subprocess.run(["bash", "scripts/check-release-version.sh", "v0.9.0", reported],
                                        cwd=self.root, capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode == 0, accepted, result.stderr)


if __name__ == "__main__":
    unittest.main()
