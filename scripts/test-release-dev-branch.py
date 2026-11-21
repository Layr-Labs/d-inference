#!/usr/bin/env python3
"""Offline scoping checks for the dev-branch provider lane.

`.github/workflows/release-dev-branch.yml` is a thin caller: a coalesced
6-hour schedule (gated on a cheap ubuntu-24.04 check) or a manual
`workflow_dispatch` on `dev` calls the reusable `.github/workflows/release-provider.yml`
with environment `dev`, which builds, signs with the Developer ID, notarizes
and publishes the `dev` commit to the DEV coordinator. Dev builds dev and
master builds master.

These assertions pin the caller: its `qualify` and `dev` jobs run only on
`workflow_dispatch` for `refs/heads/dev`. Job `qualify` calls the reusable
`release-qualify.yml` (the SDK qualification, whose shards may run on a
Darkbloom Sandbox) with read-only permissions and no secrets. Job `dev` needs
it, calls the reusable workflow with environment `dev` and `secrets: inherit`,
and names no secret or signing path of its own. The
scheduled `gate` job runs on `ubuntu-24.04` without secrets or `contents: write`
and dispatches `release-dev-branch.yml` on `dev` only when release-relevant
paths (matching `release-swift.yml`'s master push paths) changed since the last
green run. They also pin the reusable workflow's dev path: the secrets it reads
for a non-prod, non-staging lane are exactly the Apple signing and notarization
set, used only in the signing job, plus DEV_* secrets; each job that reads one
names the lane's GitHub environment, which is `dev` for this lane; it never
signs ad-hoc; its signing job has a bounded timeout and verifies the fan helper
against the Apple-team requirement; its Linux orchestration jobs run on free
`ubuntu-24.04`; and its publication serializes per environment.

actionlint validates the complete YAML syntax; this test pins the trust scope.
"""

import datetime
import json
import os
import re
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
WORKFLOW = ROOT / ".github/workflows/release-dev-branch.yml"
RELEASE_SWIFT = ROOT / ".github/workflows/release-swift.yml"
RELEASE_PROVIDER = ROOT / ".github/workflows/release-provider.yml"
DEV_GUARD = "    if: github.event_name == 'workflow_dispatch' && github.ref == 'refs/heads/dev'\n"
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
    """Return the `paths:` list of the push trigger, in order."""
    paths = push_trigger(text).split("\n    paths:\n", 1)[1]
    return re.findall(r"(?m)^      - '([^']+)'$", paths)


def gate_patterns(text):
    """Return the PATTERNS list inside the scheduled gate job, in order."""
    block = text.split("PATTERNS = [", 1)[1].split("]", 1)[0]
    return re.findall(r"'([^']+)'", block)


def jobs(text):
    """Return each job's body keyed by job id."""
    body = top_level_block(text, "jobs")
    parts = re.split(r"(?m)^  ([a-z][a-z0-9_-]*):\n", body)
    return dict(zip(parts[1::2], parts[2::2]))


def without_comments(text):
    return re.sub(r"(?m)^\s*#.*$", "", text)


def secret_references(text):
    """Yield (expression, offset of the `secrets` word) for every `secrets`
    word inside `${{ }}`.
    Expressions are case-insensitive, so the search is too."""
    for expression in re.finditer(r"\$\{\{(.*?)\}\}", text, re.S):
        for match in re.finditer(r"(?<![A-Za-z0-9_.])secrets(?![A-Za-z0-9_])",
                                 expression.group(1), re.I):
            yield expression.group(1), expression.start(1) + match.start()


class ReleaseDevBranchCallerTests(unittest.TestCase):
    def setUp(self):
        self.text = WORKFLOW.read_text(encoding="utf-8")
        self.code = without_comments(self.text)
        self.on_block = top_level_block(self.text, "on")
        self.jobs = jobs(self.text)

    def test_schedule_and_dispatch_are_the_only_triggers(self):
        self.assertEqual(re.findall(r"(?m)^  ([a-z_]+):", self.on_block), ["schedule", "workflow_dispatch"])
        self.assertIn("cron: '23 */6 * * *'", self.on_block)
        for token in ("push:", "pull_request", "workflow_call:", "workflow_run:",
                      "repository_dispatch:", "inputs.", "github.event.inputs"):
            self.assertNotIn(token, self.code, token)

    def test_gate_patterns_equal_release_swift_master_push_paths(self):
        expected = push_paths(RELEASE_SWIFT.read_text(encoding="utf-8"))
        self.assertIn(".github/workflows/release-swift.yml", expected)
        expected = [".github/workflows/release-dev-branch.yml"
                    if path == ".github/workflows/release-swift.yml" else path
                    for path in expected]
        self.assertEqual(gate_patterns(self.text), expected)

    def test_qualification_is_a_secret_free_read_only_call_before_the_release(self):
        # The plane refuses a Darkbloom-routable job inside a call that passes
        # secrets, and qualification must pass before anything is signed.
        job = self.jobs["qualify"]
        self.assertIn(DEV_GUARD, job)
        self.assertEqual(re.findall(r"(?m)^    uses: (.+)$", job), ["./.github/workflows/release-qualify.yml"])
        self.assertEqual(
            [key for key in re.findall(r"(?m)^    ([a-z_-]+):", without_comments(job))],
            ["if", "permissions", "uses", "with"])
        self.assertIn("\n    permissions:\n      contents: read\n    uses:", job)
        self.assertNotRegex(without_comments(job), r"(?i)secrets")
        with_block = job.split("\n    with:\n", 1)[1]
        self.assertEqual(re.findall(r"(?m)^      ([a-z_]+): (.+)$", with_block), [("environment", "dev")])
        self.assertRegex(self.jobs["dev"], r"(?m)^    needs: qualify$")

    def test_the_gate_qualify_and_dev_jobs_are_strictly_scoped(self):
        self.assertEqual(set(self.jobs), {"gate", "qualify", "dev"})
        gate = self.jobs["gate"]
        self.assertIn("    if: github.event_name == 'schedule'\n", gate)
        self.assertIn("    runs-on: ubuntu-24.04\n", gate)
        self.assertIn("      contents: read\n      actions: write\n", gate)
        self.assertNotIn("contents: write", gate)
        self.assertNotIn("secrets", gate)
        self.assertIn('gh workflow run release-dev-branch.yml --repo "$REPOSITORY" --ref dev', gate)

        job = self.jobs["dev"]
        self.assertIn(DEV_GUARD, job)
        self.assertEqual(len(re.findall(r"(?m)^    if:", job)), 1)
        # A local path: the reusable workflow of the dispatched dev commit, no @ref.
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
            ["needs", "if", "permissions", "uses", "with", "secrets"])
        self.assertIn("\n    secrets: inherit\n", job)
        # The caller grants exactly what the reusable workflow declares.
        self.assertIn("\n    permissions:\n      contents: write\n      actions: read\n", job)
        self.assertIn("\npermissions:\n  contents: read\n", self.text)

    def test_the_caller_has_no_build_or_signing_path_of_its_own(self):
        # No checkout, no macOS runner, and no signing in the caller.
        for token in ("actions/checkout", "codesign", "notarytool", "xcrun", "DEVELOPER_ID", "blacksmith-"):
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
                         ["      environment: dev", "      environment: dev"])
        for token in ("PROD_", "STAGING_", "'prod'", '"prod"', "'staging'", "refs/tags",
                      "tags:", "github.ref_type", "ref_name"):
            self.assertNotIn(token, self.code, token)

    def test_serialization_group_separates_schedule_from_dev_and_cancels_stale(self):
        self.assertIn(
            "\nconcurrency:\n"
            "  group: release-dev-branch-${{ github.event_name == 'schedule' && 'schedule' || 'dev' }}\n"
            "  cancel-in-progress: true\n",
            self.text)

    def test_scheduled_gate_fails_open_on_api_errors_and_skips_unchanged_dev(self):
        script = textwrap.dedent(self.jobs["gate"].split("        run: |\n", 1)[1])

        def run_gate(stub_body):
            with tempfile.TemporaryDirectory() as tmp:
                bin_dir = Path(tmp) / "bin"
                bin_dir.mkdir()
                log = Path(tmp) / "gh.log"
                stub = bin_dir / "gh"
                stub.write_text("#!/usr/bin/env bash\nset -euo pipefail\n" + stub_body, encoding="utf-8")
                stub.chmod(0o755)
                env = {**os.environ, "PATH": f"{bin_dir}:{os.environ['PATH']}", "GH_LOG": str(log),
                       "GH_TOKEN": "tok", "REPOSITORY": "Layr-Labs/d-inference"}
                proc = subprocess.run(["bash", "-c", script], env=env, capture_output=True, text=True, timeout=15)
                dispatched = log.read_text(encoding="utf-8") if log.exists() else ""
                return proc, dispatched

        # 1. Transient API failure on last_green fails open and dispatches.
        proc, dispatched = run_gate(
            'if [ "$1" = workflow ]; then echo "$*" >> "$GH_LOG"; exit 0; fi\n'
            'case "$2" in\n'
            '  *status=success*) exit 1 ;;\n'
            '  *git/ref/heads/dev) echo "aaaa" ;;\n'
            '  *) echo "" ;;\n'
            'esac\n'
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("workflow run release-dev-branch.yml --repo Layr-Labs/d-inference --ref dev", dispatched)

        # 2. Diverged compare status fails open even when files is empty.
        proc, dispatched = run_gate(
            'if [ "$1" = workflow ]; then echo "$*" >> "$GH_LOG"; exit 0; fi\n'
            'case "$2" in\n'
            '  *status=success*) echo "aaaa" ;;\n'
            '  *git/ref/heads/dev) echo "bbbb" ;;\n'
            '  *compare/aaaa...bbbb) echo \'{"status":"diverged","files":[]}\' ;;\n'
            '  *) echo "" ;;\n'
            'esac\n'
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("workflow run release-dev-branch.yml", dispatched)

        # 3. Malformed compare JSON fails open instead of aborting under set -e.
        proc, dispatched = run_gate(
            'if [ "$1" = workflow ]; then echo "$*" >> "$GH_LOG"; exit 0; fi\n'
            'case "$2" in\n'
            '  *status=success*) echo "aaaa" ;;\n'
            '  *git/ref/heads/dev) echo "bbbb" ;;\n'
            '  *compare/aaaa...bbbb) echo "{not-json" ;;\n'
            '  *) echo "" ;;\n'
            'esac\n'
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("workflow run release-dev-branch.yml", dispatched)

        # 4. Identical dev HEAD skips without dispatching.
        proc, dispatched = run_gate(
            'if [ "$1" = workflow ]; then echo "$*" >> "$GH_LOG"; exit 0; fi\n'
            'case "$2" in\n'
            '  *status=success*) echo "aaaa" ;;\n'
            '  *git/ref/heads/dev) echo "aaaa" ;;\n'
            '  *) echo "" ;;\n'
            'esac\n'
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(dispatched, "")

        # 5. Ahead compare with docs-only diff skips; provider-swift change dispatches.
        for filename, should_dispatch in (("docs/README.md", False), ("provider-swift/Sources/x.swift", True)):
            with self.subTest(filename=filename):
                proc, dispatched = run_gate(
                    'if [ "$1" = workflow ]; then echo "$*" >> "$GH_LOG"; exit 0; fi\n'
                    'case "$2" in\n'
                    '  *status=success*) echo "aaaa" ;;\n'
                    '  *git/ref/heads/dev) echo "bbbb" ;;\n'
                    f'  *compare/aaaa...bbbb) echo \'{{"status":"ahead","files":[{{"filename":"{filename}"}}]}}\' ;;\n'
                    '  *) echo "" ;;\n'
                    'esac\n'
                )
                self.assertEqual(proc.returncode, 0, proc.stderr)
                self.assertEqual(bool(dispatched), should_dispatch)


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
        # Each job that reads one of them names the lane's GitHub environment,
        # which is dev for a dev-branch release; no job names a fixed one.
        self.assertNotRegex(self.text, r"(?m)^\s+environment: (prod|staging|dev)\s*$")
        reading = [name for name, body in self.jobs.items() if list(secret_references(body))]
        self.assertEqual(reading, [SIGNING_JOB, "stage-release", "publish-release"])
        lane = {SIGNING_JOB: "build_environment", "stage-release": "build_environment", "publish-release": "deployment"}
        for name, body in self.jobs.items():
            named = re.findall(r"(?m)^    environment: (.+)$", body)
            self.assertEqual(named, [f"${{{{ needs.resolve-env.outputs.{lane[name]} || 'prod' }}}}"]
                             if name in reading else [], name)
        self.assertIn("(steps.pick.outputs.environment == 'dev' && steps.pick.outputs.publish == 'true' && 'dev')",
                      self.jobs["resolve-env"])

    def test_dev_path_signs_with_the_developer_id_never_ad_hoc(self):
        signing = self.jobs[SIGNING_JOB]
        self.assertIn("    timeout-minutes: 90\n", signing)
        self.assertIn('--sign "$DEVELOPER_ID"', signing)
        self.assertIn("xcrun notarytool submit", signing)
        self.assertIn('xcrun stapler staple "$APP"', signing)
        code = without_comments(self.text)
        for token in ("--sign -", "--sign=-", "codesign -s -"):
            self.assertNotIn(token, code, token)
        # The fan helper is verified against the team and signing-certificate
        # requirement.
        self.assertIn('FAN_HELPER_REQUIREMENT="anchor apple generic and identifier '
                      '\\"$FAN_HELPER_ID\\" and certificate leaf[subject.OU] = '
                      '\\"$APPLE_TEAM_ID\\" and $SIGNING_CERTIFICATE_REQUIREMENT"', signing)
        self.assertIn('"-R=$FAN_HELPER_REQUIREMENT"', signing)

    def test_linux_orchestration_jobs_use_hosted_ubuntu_and_macos_keeps_blacksmith(self):
        for linux_job in ("resolve-env", "stage-release", "publish-release"):
            self.assertIn("    runs-on: ubuntu-24.04\n", self.jobs[linux_job], linux_job)
        for mac_job in ("build-provider", "build-and-release"):
            self.assertIn("    runs-on: blacksmith-12vcpu-macos-27\n", self.jobs[mac_job], mac_job)
        # The SDK qualification (release-qualify.yml): its gate on ubuntu-24.04,
        # its shards on their routed lane, whose fallback is Blacksmith.
        qualify = jobs((ROOT / ".github/workflows/release-qualify.yml").read_text())
        self.assertIn("    runs-on: ubuntu-24.04\n", qualify["qualify-sdk"])
        self.assertIn("    runs-on: ${{ fromJSON(needs.route.outputs.routes)['release-qualify'] }}\n",
                      qualify["qualify-sdk-shard"])
        self.assertIn(" release-qualify macos_arm64 blacksmith-12vcpu-macos-27 ", qualify["route"])
        self.assertIn("    runs-on: blacksmith-12vcpu-macos-26\n", self.jobs["validate-older-macos"])

    def test_dev_publication_serializes_per_environment(self):
        publish = self.jobs["publish-release"]
        self.assertIn("    concurrency:\n      group: provider-publication-"
                      "${{ needs.resolve-env.outputs.environment }}\n"
                      "      cancel-in-progress: false\n", publish)
        self.assertIn("DEV_RELEASE_KEY: ${{ secrets.DEV_RELEASE_KEY }}", publish)
        self.assertIn("python3 scripts/provider-release-publication.py publish", publish)


if __name__ == "__main__":
    unittest.main()
