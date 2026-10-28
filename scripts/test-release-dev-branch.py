#!/usr/bin/env python3
"""Offline scoping checks for the dev-branch provider lane.

`.github/workflows/release-dev-branch.yml` builds a provider from the pushed
`dev` commit and publishes it to the DEV coordinator as a self-signed release.
Dev builds dev and master builds master: these assertions prove the lane starts
only on a push to `dev`, with release-swift.yml's master push paths, has no
dispatch and no `ref:` override, so both jobs use the pushed commit. Each job is
guarded to `refs/heads/dev`. The lane never selects a tag path or a GitHub
environment, never references a production secret or the production Apple
signing identity, never submits the bundle to Apple's release-signing service,
publishes only with the DEV_* secrets, never runs the built binary in the
credentialed job, and stamps a version that carries the `-dev.` marker.

actionlint validates the complete YAML syntax; this test pins the trust scope.
"""

import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
WORKFLOW = ROOT / ".github/workflows/release-dev-branch.yml"
RELEASE_SWIFT = ROOT / ".github/workflows/release-swift.yml"
DEV_GUARD = "    if: github.ref == 'refs/heads/dev'\n"


def top_level_block(text, key):
    """Return the body of a top-level `key:` mapping, up to the next top-level key."""
    body = text.split(f"\n{key}:\n", 1)[1]
    end = re.search(r"(?m)^[A-Za-z_-]+:", body)
    return body[:end.start()] if end else body


def push_trigger(text):
    """Return the body of the `on.push` trigger without comment lines."""
    push = ("\n" + top_level_block(text, "on")).split("\n  push:\n", 1)[1]
    push = re.split(r"(?m)^  [a-z_]+:", push, maxsplit=1)[0]
    return re.sub(r"(?m)^\s*#.*\n", "", push)


def push_paths(text):
    """Return the `paths:` list of the push trigger, in order. `paths` is the
    last key of both push triggers, so the list runs to the end of the block."""
    paths = push_trigger(text).split("\n    paths:\n", 1)[1]
    return re.findall(r"(?m)^      - '([^']+)'$", paths)


def jobs(text):
    """Return each job's body keyed by job id."""
    body = top_level_block(text, "jobs")
    parts = re.split(r"(?m)^  ([a-z][a-z0-9_-]*):\n", body)
    return dict(zip(parts[1::2], parts[2::2]))


class ReleaseDevBranchScopeTests(unittest.TestCase):
    def setUp(self):
        self.text = WORKFLOW.read_text(encoding="utf-8")
        self.on_block = top_level_block(self.text, "on")
        self.jobs = jobs(self.text)

    def test_workflow_file_exists(self):
        self.assertTrue(WORKFLOW.is_file(), WORKFLOW)

    def test_push_to_dev_is_the_only_trigger(self):
        # A push is the only event, and only a dev branch push starts it.
        self.assertEqual(re.findall(r"(?m)^  ([a-z_]+):", self.on_block), ["push"])
        push = push_trigger(self.text)
        self.assertEqual(re.findall(r"(?m)^    ([a-z_-]+):", push), ["branches", "paths"])
        self.assertIn("\n    branches: [dev]\n", "\n" + push)
        for token in ("tags", "branches-ignore", "paths-ignore", "master", "main"):
            self.assertNotRegex(push, rf"\b{token}\b", token)

    def test_no_dispatch_and_no_input(self):
        # A re-run of a push run rebuilds the same commit; no other entry point
        # may pick a different source.
        for token in ("workflow_dispatch", "workflow_call", "workflow_run",
                      "repository_dispatch", "pull_request", "schedule",
                      "inputs.", "github.event.inputs"):
            self.assertNotIn(token, self.text, token)

    def test_push_paths_equal_release_swift_master_push_paths(self):
        expected = push_paths(RELEASE_SWIFT.read_text(encoding="utf-8"))
        self.assertIn(".github/workflows/release-swift.yml", expected)
        expected = [".github/workflows/release-dev-branch.yml"
                    if path == ".github/workflows/release-swift.yml" else path
                    for path in expected]
        self.assertEqual(push_paths(self.text), expected)

    def test_every_checkout_uses_the_pushed_commit(self):
        # No `ref:` anywhere: build-sign compiles github.sha and publish runs the
        # same commit's scripts, so the shared build action's HEAD == GITHUB_SHA
        # check holds by design.
        self.assertNotRegex(self.text, r"(?m)^\s+ref:")
        self.assertEqual(self.text.count("uses: actions/checkout@"), 2)
        for name, body in self.jobs.items():
            with self.subTest(job=name):
                self.assertEqual(body.count("uses: actions/checkout@"), 1)
                self.assertIn("persist-credentials: false", body)
        self.assertIn("submodules: recursive", self.jobs["build-sign"])
        self.assertIn('run-name: >-\n  dev-branch provider build of ${{ github.sha }}', self.text)

    def test_every_job_is_guarded_to_the_dev_branch(self):
        self.assertEqual(set(self.jobs), {"build-sign", "publish"})
        for name, body in self.jobs.items():
            with self.subTest(job=name):
                self.assertIn(DEV_GUARD, body)
                self.assertEqual(len(re.findall(r"(?m)^    if:", body)), 1)

    def test_no_tag_path_anywhere(self):
        for token in ("refs/tags", "tags:", "ref_type == 'tag'",
                      "github.ref_type", "ref_name"):
            self.assertNotIn(token, self.text, token)

    def test_no_production_environment_or_secret(self):
        for token in ("PROD_", "environment: prod", "ENV_PREFIX: prod",
                      "environment=prod", "'prod'", '"prod"', "secrets.PROD",
                      "secrets.APPLE", "secrets.RELEASE_KEY",
                      "secrets.PROVISIONING_PROFILE", "secrets: inherit"):
            self.assertNotIn(token, self.text, token)
        # The DEV_* values are repository secrets; no job attaches a GitHub
        # environment, whose secrets would shadow or widen them.
        self.assertNotRegex(self.text, r"(?m)^\s+environment:")
        # Every secret the file names is a dev secret.
        secrets = re.findall(r"secrets\.([A-Za-z0-9_]+)", self.text)
        self.assertTrue(secrets)
        for secret in secrets:
            self.assertTrue(secret.startswith("DEV_"), secret)
        # The publication job is pinned to the dev environment.
        self.assertIn("ENV_PREFIX: dev", self.text)

    def test_no_production_signing_identity_or_apple_release_submission(self):
        # The production Apple signing identity and release-signing submission
        # live only in release-swift.yml and must never appear here.
        for token in ("DEVELOPER_ID", "Developer ID", "Developer-ID",
                      "notariz", "notary", "APPLE_CERTIFICATE",
                      "APPLE_TEAM_ID", "stapler", "xcrun"):
            self.assertNotIn(token, self.text, token)
        # Signing is ad-hoc only.
        self.assertIn("codesign --force --sign - ", self.text)

    def test_publishes_only_with_the_dev_release_key(self):
        self.assertIn("RELEASE_KEY: ${{ secrets.DEV_RELEASE_KEY }}", self.text)
        self.assertRegex(self.text, r"secrets\.DEV_R2_ACCESS_KEY_ID")
        self.assertRegex(self.text, r"secrets\.DEV_COORDINATOR_URL")
        # The shared publication script registers the release and advances the
        # dev latest aliases only when the coordinator reports it as latest.
        self.assertIn(
            "python3 scripts/provider-release-publication.py publish", self.text)

    def test_version_carries_the_dev_marker_and_the_branch_segment(self):
        # Carrying -dev. makes the installer pick the dev identity; the branch
        # segment keeps it distinct from the master dev lane's -dev.N.
        self.assertIn("-dev.branch.", self.text)
        match = re.search(r'VERSION="\$\{BASE\}(-dev\.branch\.\$\{RUN_NUMBER\})"',
                          self.text)
        self.assertIsNotNone(match, "dev-branch version string not found")

    def test_serialization_groups_are_unchanged(self):
        # The workflow serializes with itself; publish joins release-provider.yml's
        # dev publication group so the two dev lanes never register at once.
        self.assertIn("\nconcurrency:\n  group: release-dev-branch\n  cancel-in-progress: false\n",
                      self.text)
        self.assertIn("    concurrency:\n      group: provider-publication-dev\n"
                      "      cancel-in-progress: false\n", self.jobs["publish"])

    def test_build_sign_job_references_no_secret(self):
        # The build-sign job compiles and ad-hoc signs the pushed commit. It must
        # hold no credential, so its body references no secret; every `secrets.`
        # reference lives in the publish job.
        self.assertNotIn("secrets.", self.jobs["build-sign"])
        self.assertIn("secrets.", self.jobs["publish"])

    def test_publish_never_executes_the_built_binary(self):
        # The credentialed job receives the built bytes only as the downloaded
        # bundle. It never extracts the bundle or runs a binary from it.
        publish = self.jobs["publish"]
        self.assertIn("needs: build-sign", publish)
        self.assertIn('gh run download "$GITHUB_RUN_ID"', publish)
        for token in ("tar x", "tar -x", "tar z", "tar -z", "ditto", "codesign",
                      "bin/darkbloom", "PRODUCT_CLI_NAME", "CLI_NAME", "Contents/MacOS",
                      ".app", "--version", "BIN_DIR", "chmod"):
            self.assertNotIn(token, publish, token)


if __name__ == "__main__":
    unittest.main()
