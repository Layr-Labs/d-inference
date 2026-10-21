#!/usr/bin/env python3
"""Offline scoping checks for the experimental dev-branch provider lane.

`.github/workflows/release-dev-branch.yml` builds a provider from any branch and
publishes it to the DEV coordinator as a self-signed release. These assertions
prove the lane cannot reach production: it is dispatch-only with a `ref` input,
it never selects a tag path or a production environment, it never references a
production secret or the production Apple signing identity, it never submits the
bundle to Apple's release-signing service, it publishes only with
`DEV_RELEASE_KEY`, and the version it stamps carries the `-dev.` marker.

actionlint validates the complete YAML syntax; this test pins the trust scope.
"""

import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
WORKFLOW = ROOT / ".github/workflows/release-dev-branch.yml"


class ReleaseDevBranchScopeTests(unittest.TestCase):
    def setUp(self):
        self.text = WORKFLOW.read_text(encoding="utf-8")

    def test_workflow_file_exists(self):
        self.assertTrue(WORKFLOW.is_file(), WORKFLOW)

    def test_dispatch_only_with_a_required_ref_input(self):
        on_block = self.text.split("\njobs:", 1)[0]
        self.assertIn("workflow_dispatch:", on_block)
        # No other trigger may put this credentialed logic on unreviewed code.
        for trigger in ("\n  push:", "\n  pull_request:", "\n  schedule:",
                        "\n  release:"):
            self.assertNotIn(trigger, on_block)
        # A required string `ref` input selects the branch or SHA to build.
        self.assertRegex(
            on_block,
            r"\n      ref:\n(?:        .*\n)*?        required: true\n")
        self.assertRegex(
            on_block,
            r"\n      ref:\n(?:        .*\n)*?        type: string\n")

    def test_no_tag_path_anywhere(self):
        for token in ("refs/tags", "tags:", "ref_type == 'tag'",
                      "github.ref_type", "ref_name"):
            self.assertNotIn(token, self.text, token)

    def test_no_production_environment_or_secret(self):
        for token in ("PROD_", "environment: prod", "ENV_PREFIX: prod",
                      "environment=prod", "'prod'", '"prod"', "secrets.PROD",
                      "secrets.APPLE", "secrets.RELEASE_KEY",
                      "secrets.PROVISIONING_PROFILE"):
            self.assertNotIn(token, self.text, token)
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
        # The dev coordinator ordering by created_at makes a fresh publish the
        # latest dev release; it uses the shared publication script.
        self.assertIn(
            "python3 scripts/provider-release-publication.py publish", self.text)

    def test_version_carries_the_dev_marker_and_the_branch_segment(self):
        # Carrying -dev. makes the installer pick the dev identity; the branch
        # segment keeps it distinct from the master dev lane's -dev.N.
        self.assertIn("-dev.branch.", self.text)
        match = re.search(r'VERSION="\$\{BASE\}(-dev\.branch\.\$\{RUN_NUMBER\})"',
                          self.text)
        self.assertIsNotNone(match, "dev-branch version string not found")

    def test_credentialed_publish_runs_the_reviewed_master_scripts(self):
        # The publish job must check out master, not the dispatched ref, so the
        # credentialed publication logic is always the reviewed copy.
        publish = self.text.split("\n  publish:", 1)[1]
        self.assertIn("ref: master", publish)
        self.assertNotIn("ref: ${{ inputs.ref }}", publish)

    def test_build_sign_job_references_no_secret(self):
        # The build-sign job compiles and ad-hoc signs the dispatched branch
        # code. It must hold no credential, so its body references no secret;
        # every `secrets.` reference lives in the publish job, which runs the
        # reviewed master scripts and never executes the branch binary.
        build_sign = self.text.split("\n  build-sign:", 1)[1].split("\n  publish:", 1)[0]
        self.assertNotIn("secrets.", build_sign)


if __name__ == "__main__":
    unittest.main()
