#!/usr/bin/env python3
"""Offline scoping checks for the dev-branch provider lane.

`.github/workflows/release-dev-branch.yml` is a thin caller: a push to `dev`
calls the reusable `.github/workflows/release-provider.yml` with environment
`dev`, which builds, signs with the Developer ID, notarizes and publishes the
pushed commit to the DEV coordinator. Dev builds dev and master builds master.

These assertions pin the caller: it starts only on a push to `dev`, with
release-swift.yml's master push paths, has no dispatch, no input and no
`ref:`, and its one job is guarded to `refs/heads/dev` and only calls the
reusable workflow with environment `dev` and `secrets: inherit`. The caller
names no secret, has no step and signs nothing itself, so there is no second
build or signing path and no ad-hoc signature. They also pin the reusable
workflow's dev path: the secrets it reads for a non-prod, non-staging lane are
exactly the Apple signing and notarization set, used only in the signing job,
plus DEV_* secrets; it never signs ad-hoc; its signing job verifies the fan
helper against the Apple-team requirement; and its publication serializes per
environment.

actionlint validates the complete YAML syntax; this test pins the trust scope.
"""

import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
WORKFLOW = ROOT / ".github/workflows/release-dev-branch.yml"
RELEASE_SWIFT = ROOT / ".github/workflows/release-swift.yml"
RELEASE_PROVIDER = ROOT / ".github/workflows/release-provider.yml"
DEV_GUARD = "    if: github.ref == 'refs/heads/dev'\n"
# The Apple secrets every Developer ID lane reads; shared by all environments.
APPLE_SIGNING_SECRETS = {
    "APPLE_CERTIFICATE_P12", "APPLE_CERTIFICATE_PASSWORD",
    "PROVISIONING_PROFILE_BASE64", "APPLE_ID", "APPLE_APP_PASSWORD",
}
SIGNING_JOB = "build-and-release"
# A prod or staging secret is read only behind this exact environment guard.
GUARDED_SECRET = re.compile(
    r"^\s*needs\.resolve-env\.outputs\.environment == '(prod|staging)' && "
    r"secrets\.[A-Z0-9_]+ \|\| ''\s*$")
ADHOC_SIGNING = ("--sign -", "--sign=-", "codesign -s -", "-s - ", "self-sign",
                 "ad-hoc", "adhoc")


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


def without_comments(text):
    return re.sub(r"(?m)^\s*#.*$", "", text)


def secret_references(text):
    """Yield (expression, offset) for every `secrets` word inside `${{ }}`.
    Expressions are case-insensitive, so the search is too."""
    for expression in re.finditer(r"\$\{\{(.*?)\}\}", text, re.S):
        for match in re.finditer(r"(?<![A-Za-z0-9_.])secrets(?![A-Za-z0-9_])",
                                 expression.group(1), re.I):
            yield expression.group(1), expression.start()


class ReleaseDevBranchCallerTests(unittest.TestCase):
    def setUp(self):
        self.text = WORKFLOW.read_text(encoding="utf-8")
        self.code = without_comments(self.text)
        self.on_block = top_level_block(self.text, "on")
        self.jobs = jobs(self.text)

    def test_push_to_dev_is_the_only_trigger(self):
        # A push is the only event, and only a dev branch push starts it.
        self.assertEqual(re.findall(r"(?m)^  ([a-z_]+):", self.on_block), ["push"])
        push = push_trigger(self.text)
        self.assertEqual(re.findall(r"(?m)^    ([a-z_-]+):", push), ["branches", "paths"])
        self.assertIn("\n    branches: [dev]\n", "\n" + push)
        for token in ("tags", "branches-ignore", "paths-ignore", "master", "main"):
            self.assertNotRegex(push, rf"\b{token}\b", token)

    def test_no_dispatch_and_no_input(self):
        # No entry point may pick a different source than the pushed commit.
        for token in ("workflow_dispatch", "workflow_call", "workflow_run",
                      "repository_dispatch", "pull_request", "schedule",
                      "inputs.", "github.event.inputs"):
            self.assertNotIn(token, self.code, token)

    def test_push_paths_equal_release_swift_master_push_paths(self):
        expected = push_paths(RELEASE_SWIFT.read_text(encoding="utf-8"))
        self.assertIn(".github/workflows/release-swift.yml", expected)
        expected = [".github/workflows/release-dev-branch.yml"
                    if path == ".github/workflows/release-swift.yml" else path
                    for path in expected]
        self.assertEqual(push_paths(self.text), expected)

    def test_the_only_job_is_the_guarded_call_of_the_reusable_workflow(self):
        self.assertEqual(set(self.jobs), {"dev"})
        job = self.jobs["dev"]
        self.assertIn(DEV_GUARD, job)
        self.assertEqual(len(re.findall(r"(?m)^    if:", job)), 1)
        # A local path: the reusable workflow of the pushed commit, no @ref.
        self.assertEqual(re.findall(r"(?m)^    uses: (.+)$", job),
                         ["./.github/workflows/release-provider.yml"])
        # Exactly one input, environment dev; the version, resume and
        # validation inputs keep their defaults.
        with_block = job.split("\n    with:\n", 1)[1]
        with_block = re.split(r"(?m)^    [a-z]", with_block, maxsplit=1)[0]
        self.assertEqual(re.findall(r"(?m)^      ([a-z_]+): (.+)$", with_block),
                         [("environment", "dev")])
        self.assertEqual(
            [key for key in re.findall(r"(?m)^    ([a-z_-]+):", without_comments(job))],
            ["if", "permissions", "uses", "with", "secrets"])
        self.assertIn("\n    secrets: inherit\n", job)
        # The caller grants exactly what the reusable workflow declares.
        self.assertIn("\n    permissions:\n      contents: write\n      actions: read\n", job)
        self.assertIn("\npermissions:\n  contents: read\n", self.text)

    def test_the_caller_has_no_build_or_signing_path_of_its_own(self):
        # No step, no runner, no checkout and no signing in the caller.
        for token in ("steps:", "runs-on:", "run:", "actions/checkout",
                      "codesign", "notarytool", "xcrun", "DEVELOPER_ID"):
            self.assertNotIn(token, self.code, token)
        for token in ADHOC_SIGNING:
            self.assertNotIn(token, self.code, token)
        self.assertNotRegex(self.text, r"(?m)^\s+ref:")
        self.assertIn('run-name: >-\n  dev-branch provider release of ${{ github.sha }} '
                      '(-dev.branch.${{ github.run_number }})', self.text)

    def test_the_caller_names_no_secret_and_no_environment(self):
        # `secrets: inherit` on the call is the only secret reference; no
        # expression reads the secrets context, and no job attaches a GitHub
        # environment.
        self.assertEqual(list(secret_references(self.text)), [])
        self.assertEqual(re.findall(r"(?i)(?<![A-Za-z0-9_])secrets(?![A-Za-z0-9_])", self.code),
                         ["secrets"])
        self.assertEqual(self.code.count("secrets: inherit"), 1)
        self.assertEqual(re.findall(r"(?m)^\s+environment:.*$", self.code),
                         ["      environment: dev"])
        for token in ("PROD_", "STAGING_", "'prod'", '"prod"', "'staging'", "refs/tags",
                      "tags:", "github.ref_type", "ref_name"):
            self.assertNotIn(token, self.code, token)

    def test_serialization_group_is_unchanged(self):
        self.assertIn("\nconcurrency:\n  group: release-dev-branch\n  cancel-in-progress: false\n",
                      self.text)


class ReusableDevPathTests(unittest.TestCase):
    """The reusable workflow's path for environment dev, which the caller runs."""

    def setUp(self):
        self.text = RELEASE_PROVIDER.read_text(encoding="utf-8")
        self.jobs = jobs(self.text)

    def test_dev_reads_only_the_apple_signing_set_and_dev_secrets(self):
        # Every secret read without a prod or staging guard is a DEV_* secret
        # or one of the Apple signing secrets, and each Apple secret is read
        # only in the signing job.
        unguarded = set()
        for name, body in self.jobs.items():
            for expression, _ in secret_references(body):
                if GUARDED_SECRET.match(expression):
                    continue
                match = re.fullmatch(r"\s*secrets\.([A-Z0-9_]+)\s*", expression)
                self.assertIsNotNone(match, expression)
                secret = match.group(1)
                unguarded.add(secret)
                if secret in APPLE_SIGNING_SECRETS:
                    self.assertEqual(name, SIGNING_JOB, secret)
                else:
                    self.assertTrue(secret.startswith("DEV_"), secret)
        self.assertEqual(unguarded & APPLE_SIGNING_SECRETS, APPLE_SIGNING_SECRETS)
        self.assertIn("DEV_RELEASE_KEY", unguarded)
        self.assertNotRegex(self.text, r"(?m)^\s+environment: (prod|staging|dev)\s*$")

    def test_dev_path_signs_with_the_developer_id_never_ad_hoc(self):
        signing = self.jobs[SIGNING_JOB]
        self.assertIn('--sign "$DEVELOPER_ID"', signing)
        self.assertIn("xcrun notarytool submit", signing)
        self.assertIn('xcrun stapler staple "$APP"', signing)
        code = without_comments(self.text)
        for token in ("--sign -", "--sign=-", "codesign -s -"):
            self.assertNotIn(token, code, token)
        # The fan helper is verified against the Apple-team requirement.
        self.assertIn('FAN_HELPER_REQUIREMENT="anchor apple generic and identifier '
                      '\\"$FAN_HELPER_ID\\" and certificate leaf[subject.OU] = '
                      '\\"$APPLE_TEAM_ID\\""', signing)
        self.assertIn('"-R=$FAN_HELPER_REQUIREMENT"', signing)

    def test_dev_publication_serializes_per_environment(self):
        publish = self.jobs["publish-release"]
        self.assertIn("    concurrency:\n      group: provider-publication-"
                      "${{ needs.resolve-env.outputs.environment }}\n"
                      "      cancel-in-progress: false\n", publish)
        self.assertIn("DEV_RELEASE_KEY: ${{ secrets.DEV_RELEASE_KEY }}", publish)
        self.assertIn("python3 scripts/provider-release-publication.py publish", publish)


if __name__ == "__main__":
    unittest.main()
