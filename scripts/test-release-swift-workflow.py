#!/usr/bin/env python3
"""Bounded release policy tests; requires PyYAML, never builds or notarizes."""

import hashlib
import importlib.util
import itertools
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/release-swift.yml"
spec = importlib.util.spec_from_file_location(
    "qualification", ROOT / "scripts/release-qualification-manifest.py"
)
qualification = importlib.util.module_from_spec(spec)
spec.loader.exec_module(qualification)


class ReleaseWorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # BaseLoader keeps GitHub's `on` key and expression values as strings.
        cls.workflow = yaml.load(WORKFLOW.read_text(), Loader=yaml.BaseLoader)
        cls.resolver = cls.workflow["jobs"]["resolve-env"]
        cls.job = cls.workflow["jobs"]["build-and-release"]
        cls.pick = next(s for s in cls.resolver["steps"] if s.get("id") == "pick")
        cls.steps = {s["name"]: s for s in cls.job["steps"]}
        cls.version = re.search(
            r'public static let version = "([^"]+)"',
            (ROOT / "provider-swift/Sources/ProviderCore/ProviderCore.swift").read_text(),
        )[1]

    def resolve(self, event, environment, publish, ref_type, ref_name=None, override=""):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "output"
            result = subprocess.run(
                ["bash", "-c", self.pick["run"]], cwd=ROOT, text=True,
                capture_output=True, timeout=10,
                env={**os.environ, "EVENT_NAME": event,
                     "INPUT_ENVIRONMENT": environment, "INPUT_PUBLISH_RELEASE": publish,
                     "INPUT_VERSION_OVERRIDE": override, "REF_TYPE": ref_type,
                     "REF_NAME": ref_name or (f"v{self.version}" if ref_type == "tag" else "candidate"),
                     "GITHUB_OUTPUT": str(output)},
            )
            outputs = dict(line.split("=", 1) for line in output.read_text().splitlines()) if output.exists() else {}
            return result, outputs

    def selected(self, step, outputs, ref_type, success=True):
        # All release gates deliberately use only equality/conjunction, with
        # GitHub's implicit success() guard. Reject unexpected expressions.
        if not success:
            return False
        values = {f"needs.resolve-env.outputs.{key}": value for key, value in outputs.items()}
        values["github.ref_type"] = ref_type
        condition = step.get("if")
        if condition is None:
            return True
        terms = [re.fullmatch(r"([\w.-]+) == '([^']+)'", term) for term in condition.split(" && ")]
        self.assertTrue(all(terms), condition)
        return all(values[term[1]] == term[2] for term in terms)

    def assert_delivery(self, outputs, ref_type):
        publishing = outputs["publish_release"] == "true"
        for name in ("Resolve env-specific secrets", "Install awscli (R2)",
                     "Upload release artifacts to R2", "Register release with coordinator"):
            self.assertEqual(self.selected(self.steps[name], outputs, ref_type), publishing, name)
        self.assertEqual(
            self.selected(self.steps["Create GitHub Release"], outputs, ref_type),
            publishing and outputs["environment"] == "prod" and ref_type == "tag",
        )
        for name in ("Write dev qualification manifest", "Retain qualified dev artifacts"):
            self.assertEqual(self.selected(self.steps[name], outputs, ref_type), not publishing, name)

    def test_manual_event_environment_publish_matrix(self):
        for environment, publish, ref_type in itertools.product(
            ("dev", "prod"), ("", "true", "false"), ("branch", "tag")
        ):
            with self.subTest(environment=environment, publish=publish, ref_type=ref_type):
                result, outputs = self.resolve("workflow_dispatch", environment, publish, ref_type)
                if environment == "prod" and (publish == "false" or ref_type != "tag"):
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(outputs, {})
                    error = "Qualification-only" if publish == "false" else "requires a source-matching release tag"
                    self.assertIn(error, result.stdout)
                else:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(outputs, {"environment": environment, "publish_release": publish or "true", "version": self.version})
                    self.assert_delivery(outputs, ref_type)

    def test_automatic_tags_always_publish_prod(self):
        for environment, publish, suffix in itertools.product(
            ("", "dev", "prod"), ("", "true", "false"), ("", "-swift", "-swift.1")
        ):
            with self.subTest(environment=environment, publish=publish, suffix=suffix):
                result, outputs = self.resolve("push", environment, publish, "tag", f"v{self.version}{suffix}")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(outputs, {"environment": "prod", "publish_release": "true", "version": self.version})
                self.assert_delivery(outputs, "tag")

    def test_rejects_invalid_inputs_events_and_dev_tags(self):
        cases = [
            ("workflow_dispatch", "staging", "false", "branch", "candidate"),
            ("workflow_dispatch", "dev", "False", "branch", "candidate"),
            ("workflow_dispatch", "dev", "0", "branch", "candidate"),
            ("pull_request", "dev", "false", "branch", "candidate"),
            ("push", "dev", "false", "branch", "candidate"),
            ("push", "", "", "tag", f"v{self.version}-dev.1"),
            ("workflow_dispatch", "dev", "false", "tag", f"v{self.version}-dev.1"),
            ("workflow_dispatch", "", "false", "tag", f"v{self.version}"),
        ]
        for case in cases:
            with self.subTest(case=case):
                result, outputs = self.resolve(*case)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(outputs, {})

    def test_version_cannot_inject_workflow_outputs(self):
        for suffix in ("\npublish_release=true", "\renvironment=prod",
                       "\r\npublish_release=true", "\nversion=" + self.version):
            with self.subTest(suffix=suffix):
                result, outputs = self.resolve("workflow_dispatch", "dev", "false", "branch",
                                               override=self.version + suffix)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(outputs, {})
                self.assertIn("single line", result.stdout)
        for version in ("v" + self.version, "not-a-version", self.version + " extra"):
            with self.subTest(version=version):
                result, outputs = self.resolve("workflow_dispatch", "dev", "false", "branch",
                                               override=version)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(outputs, {})
                self.assertIn("canonical SemVer", result.stdout)

    def test_dispatch_defaults_and_output_wiring(self):
        inputs = self.workflow["on"]["workflow_dispatch"]["inputs"]
        self.assertEqual(inputs["publish_release"]["type"], "boolean")
        self.assertEqual(inputs["publish_release"]["default"], "true")
        self.assertEqual(inputs["environment"]["default"], "dev")
        self.assertEqual(self.pick["env"]["INPUT_PUBLISH_RELEASE"], "${{ inputs.publish_release }}")
        self.assertEqual(self.pick["env"]["EVENT_NAME"], "${{ github.event_name }}")
        self.assertEqual(self.resolver["outputs"]["publish_release"], "${{ steps.pick.outputs.publish_release }}")
        self.assertEqual(self.job["env"]["PUBLISH_RELEASE"], "${{ needs.resolve-env.outputs.publish_release }}")
        result, outputs = self.resolve("workflow_dispatch", "", "", "tag")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(outputs["publish_release"], "true")
        self.assertEqual(outputs["environment"], "prod")

    def test_version_exactness_and_environment_gate_remain(self):
        self.assertEqual(self.job["environment"], "${{ needs.resolve-env.outputs.environment }}")
        self.assertEqual(self.job["needs"], ["resolve-env"])
        self.assertNotIn("if", self.job)
        self.assertNotIn("continue-on-error", self.job)
        version_gate = self.resolver["steps"][-1]
        self.assertEqual(version_gate["run"], './scripts/check-release-version.sh "${{ steps.pick.outputs.version }}"')
        self.assertNotIn("if", version_gate)
        for override in (self.version, "0.0.0-qualification-mismatch"):
            result, outputs = self.resolve("workflow_dispatch", "dev", "false", "branch", override=override)
            self.assertEqual(result.returncode, 0)
            self.assertEqual(outputs["version"], override)
            checked = subprocess.run(["bash", "scripts/check-release-version.sh", override],
                                     cwd=ROOT, capture_output=True, timeout=10)
            self.assertEqual(checked.returncode == 0, override == self.version)

    def test_qualification_is_unconditional_before_delivery(self):
        protected = ("Validate release version integrity", "Import Developer ID certificate",
                     "Verify production prompt parity", "Build provider-swift (release)",
                     "Embed provisioning profile", "Stage and sign bundle", "Notarize bundle")
        for name in protected:
            self.assertNotIn("if", self.steps[name], name)
            self.assertNotIn("continue-on-error", self.steps[name], name)
        names = list(self.steps)
        self.assertLess(names.index("Notarize bundle"), names.index("Write dev qualification manifest"))
        self.assertLess(names.index("Write dev qualification manifest"), names.index("Retain qualified dev artifacts"))
        for name in ("Retain qualified dev artifacts", "Upload release artifacts to R2",
                     "Register release with coordinator", "Create GitHub Release"):
            self.assertLess(names.index("Notarize bundle"), names.index(name))
            self.assertNotIn("continue-on-error", self.steps[name])
            self.assertFalse(self.selected(self.steps[name], {}, "tag", success=False))
        mutations = {name for name, step in self.steps.items() if any(
            command in step.get("run", "") for command in ("aws s3 cp", "/v1/releases", "gh release create")
        )}
        self.assertEqual(mutations, {"Upload release artifacts to R2", "Register release with coordinator", "Create GitHub Release"})
        notarize = self.steps["Notarize bundle"]["run"]
        for guard in ('"$NOTARY_STATUS" != "Accepted"', "xcrun stapler staple", "xcrun stapler validate",
                      "spctl --assess", "codesign --verify --deep --strict", "--preflight-release-archive",
                      "./scripts/qualify-signed-macos-app.sh", "runtime-smoke", "./scripts/check-release-version.sh"):
            self.assertIn(guard, notarize)
        self.assertNotIn("PUBLISH_RELEASE", notarize)

    def test_artifact_upload_is_an_exact_allowlist(self):
        upload = self.steps["Retain qualified dev artifacts"]
        self.assertRegex(upload["uses"], r"^actions/upload-artifact@[0-9a-f]{40}$")
        self.assertEqual(upload["with"]["path"].splitlines(), [
            "/tmp/Darkbloom-macOS-arm64.zip", "/tmp/darkbloom-bundle-macos-arm64.tar.gz",
            "/tmp/darkbloom-qualification-manifest.json",
        ])
        self.assertEqual(upload["with"]["if-no-files-found"], "error")
        self.assertEqual(upload["with"]["compression-level"], "0")
        self.assertEqual(set(qualification.ARCHIVES), {
            self.workflow["env"]["APP_ARCHIVE_NAME"], self.workflow["env"]["LEGACY_BUNDLE_NAME"]
        })


class QualificationManifestTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.env = {"GITHUB_EVENT_NAME": "workflow_dispatch", "ENV_PREFIX": "dev",
                    "PUBLISH_RELEASE": "false", "VERSION": "1.2.3", "GITHUB_REPOSITORY": "test/repo",
                    "GITHUB_SHA": "a" * 40, "GITHUB_REF": "refs/heads/candidate",
                    "GITHUB_WORKFLOW_REF": "test/repo/.github/workflows/release-swift.yml@refs/heads/candidate",
                    "GITHUB_WORKFLOW_SHA": "a" * 40, "GITHUB_RUN_ID": "123", "GITHUB_RUN_ATTEMPT": "2",
                    "BINARY_HASH": "b" * 64, "METALLIB_HASH": "c" * 64,
                    "APPLE_APP_PASSWORD": "secret-canary", "RELEASE_KEY": "secret-canary"}
        self.notary = {"id": "12345678-1234-4234-8234-123456789abc", "status": "Accepted",
                       "message": "secret-canary", "log": {"apple-id": "secret-canary"}}
        # Byte/hash fixtures only; these are never passed to a notary or archive validator.
        for name, key in qualification.ARCHIVES.items():
            data = name.encode()
            (self.root / name).write_bytes(data)
            self.env[key] = hashlib.sha256(data).hexdigest()

    def manifest(self):
        return qualification.qualification_manifest(self.root, self.notary, self.env)

    def test_exact_archive_hashes_and_safe_provenance(self):
        manifest = self.manifest()
        self.assertNotIn("secret-canary", json.dumps(manifest))
        self.assertEqual(manifest["notarization"], {"id": self.notary["id"], "status": "Accepted"})
        self.assertEqual(manifest["source"]["sha"], self.env["GITHUB_SHA"])
        self.assertEqual(manifest["source"]["run_attempt"], "2")
        self.assertIs(manifest["publish_release"], False)
        for archive in manifest["archives"]:
            self.assertEqual(archive["sha256"], self.env[qualification.ARCHIVES[archive["name"]]])
            self.assertEqual(archive["size_bytes"], len(archive["name"].encode()))

    def test_manifest_cli_writes_only_safe_output(self):
        notary_path = self.root / "notary-result.json"
        output = self.root / "manifest.json"
        notary_path.write_text(json.dumps(self.notary))
        result = subprocess.run(
            [sys.executable, str(ROOT / "scripts/release-qualification-manifest.py"),
             "--artifact-dir", str(self.root), "--notary-result", str(notary_path),
             "--output", str(output)],
            env={**os.environ, **self.env}, capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(output.read_text()), self.manifest())
        self.assertNotIn("secret-canary", output.read_text() + result.stdout + result.stderr)
        self.assertEqual(set(json.loads(output.read_text())), {
            "schema_version", "environment", "publish_release", "version", "source",
            "notarization", "archives", "binary_sha256", "metallib_sha256",
        })

    def test_refuses_missing_empty_changed_or_symlink_archive(self):
        archive = self.root / next(iter(qualification.ARCHIVES))
        for mode in ("missing", "empty", "changed", "symlink"):
            with self.subTest(mode=mode):
                archive.unlink(missing_ok=True)
                if mode == "symlink":
                    archive.symlink_to(self.root / list(qualification.ARCHIVES)[1])
                elif mode != "missing":
                    archive.write_bytes(b"" if mode == "empty" else b"changed")
                with self.assertRaises(ValueError):
                    self.manifest()

    def test_refuses_nonaccepted_or_malformed_notary_result(self):
        for result in ({}, {"status": "Invalid"}, {"status": "In Progress"},
                       {"status": "Accepted", "id": "secret-canary"}):
            with self.subTest(result=result):
                self.notary = result
                with self.assertRaises((ValueError, KeyError)):
                    self.manifest()

    def test_refuses_manifest_for_other_modes(self):
        for key, value in (("ENV_PREFIX", "prod"), ("PUBLISH_RELEASE", "true"), ("GITHUB_EVENT_NAME", "push")):
            with self.subTest(key=key):
                original = self.env[key]
                self.env[key] = value
                with self.assertRaises(ValueError):
                    self.manifest()
                self.env[key] = original


if __name__ == "__main__":
    unittest.main()
