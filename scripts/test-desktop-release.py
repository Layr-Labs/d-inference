#!/usr/bin/env python3
"""Offline checks of the desktop release workflow and its notarization script.

`.github/workflows/release-desktop.yml` builds, signs, packages and publishes
the desktop app in six jobs. These assertions pin what each job may hold and
run: the source gate comes from master and runs first; npm code runs only in
jobs without a secret; the two jobs with the signing key run no npm code and
nothing the build produced; every hand-off is by artifact id and digest; and
only the publication job can write repository contents.
scripts/test-sign-desktop-app.py covers the signer and
scripts/test-provider-release-resume.py the source gate.
"""
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
WORKFLOW = (ROOT / ".github/workflows/release-desktop.yml").read_text()
NOTARIZE = ROOT / "scripts/notarize-artifact.sh"
JOBS = ("source", "build", "sign", "package", "sign-dmg", "publish")
KEYED_JOBS = ("sign", "sign-dmg")
CERTIFICATE_SECRETS = ("APPLE_CERTIFICATE_P12", "APPLE_CERTIFICATE_PASSWORD")
NOTARIZATION_SECRETS = ("APPLE_ID", "APPLE_APP_PASSWORD")
DOWNLOAD = "python3 scripts/provider-release-publication.py download"


def without_comments(text):
    return re.sub(r"(?m)^\s*#.*\n", "", text)


def jobs():
    body = WORKFLOW.split("\njobs:\n", 1)[1]
    parts = re.split(r"(?m)^  ([a-z][a-z0-9-]*):\n", body)
    return dict(zip(parts[1::2], parts[2::2]))


def steps(job):
    """(name, body) of every step of a job, in order; an unnamed step is named by its action."""
    blocks = re.split(r"(?m)^      - ", without_comments(job.split("\n    steps:\n", 1)[1]))[1:]
    named = []
    for block in blocks:
        name = re.match(r"name: (.+)\n", block) or re.match(r"uses: ([^@\n]+)", block)
        named.append((name.group(1), block))
    return named


class DesktopReleaseWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.jobs = jobs()
        self.steps = {name: steps(body) for name, body in self.jobs.items()}

    def step(self, job, name):
        return dict(self.steps[job])[name]

    def names(self, job):
        return [name for name, _ in self.steps[job]]

    def test_the_jobs_and_their_order(self):
        self.assertEqual(tuple(self.jobs), JOBS)
        needs = {name: re.search(r"(?m)^    needs: (.+)$", body) for name, body in self.jobs.items()}
        self.assertIsNone(needs["source"])
        self.assertEqual({name: match.group(1) for name, match in needs.items() if match},
                         {"build": "source", "sign": "[source, build]", "package": "[source, sign]",
                          "sign-dmg": "[source, sign, package]", "publish": "[source, sign-dmg]"})
        trigger = WORKFLOW.split("\non:\n", 1)[1].split("\npermissions:", 1)[0]
        self.assertEqual(without_comments(trigger + "\n").strip(), "push:\n    tags: ['desktop-v*']\n  workflow_dispatch:")

    def test_masters_source_gate_runs_before_any_other_job(self):
        source = self.steps["source"]
        self.assertEqual(self.names("source")[:3],
                         ["actions/checkout", "Verify reviewed source before any signing credential", "actions/checkout"])
        # The policy that admits a release is master's copy, not the tagged commit's.
        self.assertIn("          ref: master\n", source[0][1])
        gate = source[1][1]
        self.assertIn("        run: python3 scripts/provider-release-resume.py verify-desktop-source\n", gate)
        self.assertIn("        id: trust\n", gate)
        self.assertIn("          ref: ${{ steps.trust.outputs.source_sha }}\n", source[2][1])
        self.assertNotIn("secrets.", self.jobs["source"])
        # Every other job waits for it and checks out the commit it admitted.
        for name in JOBS[1:]:
            with self.subTest(job=name):
                self.assertRegex(self.jobs[name], r"(?m)^    needs: (source|\[source, .+\])$")
                checkout = self.steps[name][0]
                self.assertEqual(checkout[0], "actions/checkout")
                self.assertIn("          ref: ${{ needs.source.outputs.source_sha }}\n", checkout[1])
        # No job-level condition lets a job run without the gate's success.
        self.assertEqual(re.findall(r"(?m)^    if: (.+)$", WORKFLOW), ["needs.source.outputs.publish == 'true'"])
        self.assertNotRegex(WORKFLOW, r"(?m)^    if:.*(always|cancelled|failure)")

    def test_no_checkout_leaves_a_token_in_the_git_configuration(self):
        checkouts = [body for job in self.steps.values() for name, body in job if name == "actions/checkout"]
        self.assertEqual(len(checkouts), 7)
        for body in checkouts:
            self.assertIn("          persist-credentials: false\n", body)

    def test_only_the_publication_job_can_write_repository_contents(self):
        header = WORKFLOW.split("\njobs:\n", 1)[0]
        self.assertIn("\npermissions:\n  contents: read\n  actions: read", without_comments(header))
        self.assertEqual(WORKFLOW.count("contents: write"), 1)
        self.assertIn("    permissions:\n      contents: write", self.jobs["publish"])
        for name in JOBS[:-1]:
            with self.subTest(job=name):
                self.assertIn("    permissions:\n      contents: read\n", self.jobs[name])
                self.assertNotIn("gh release create", self.jobs[name])
                self.assertNotIn("gh release upload", self.jobs[name])
        # A dry run publishes nothing, and a release is created only for its tag.
        self.assertIn("    if: needs.source.outputs.publish == 'true'\n", self.jobs["publish"])
        self.assertIn("--verify-tag --latest=false", self.jobs["publish"])

    def test_secrets_reach_one_step_each_in_the_two_signing_jobs(self):
        for name in ("source", "build", "package", "publish"):
            self.assertNotIn("secrets.", self.jobs[name], name)
        owners = {"sign": ("Import Developer ID certificate", "Notarize the app"),
                  "sign-dmg": ("Import Developer ID certificate", "Notarize the disk image")}
        for job, (importer, notarizer) in owners.items():
            with self.subTest(job=job):
                for secret in CERTIFICATE_SECRETS:
                    self.assertEqual([name for name, body in self.steps[job] if "secrets." + secret in body], [importer])
                for secret in NOTARIZATION_SECRETS:
                    self.assertEqual([name for name, body in self.steps[job] if "secrets." + secret in body], [notarizer])
                self.assertEqual(self.jobs[job].count("secrets."), 4)
                # The notarization step runs the notarization script and nothing else.
                notarize = self.step(job, notarizer)
                self.assertRegex(notarize, r'(?m)^        run: \./scripts/notarize-artifact\.sh "\$RUNNER_TEMP/\S+" '
                                           r'"\$RUNNER_TEMP/notary-(app|dmg)\.json"\n\Z')
        self.assertEqual(WORKFLOW.count("secrets."), 8)

    def test_signing_and_publication_run_in_the_prod_environment(self):
        # prod's branch and tag policy and its reviewers apply before a job
        # that signs or publishes starts; the jobs that run npm code name no
        # environment, so no environment secret can reach them.
        named = {name: re.findall(r"(?m)^    environment: (.+)$", body) for name, body in self.jobs.items()}
        self.assertEqual(named, {"source": [], "build": [], "sign": ["prod"], "package": [],
                                 "sign-dmg": ["prod"], "publish": ["prod"]})
        for name, body in self.jobs.items():
            if "secrets." in body:
                self.assertEqual(named[name], ["prod"], name)

    def test_the_signing_key_exists_for_the_codesign_step_alone(self):
        signers = {"sign": "Sign the app", "sign-dmg": "Sign the disk image"}
        for job, signer in signers.items():
            with self.subTest(job=job):
                names = self.names(job)
                imported = names.index("Import Developer ID certificate")
                self.assertEqual(names[imported:imported + 3],
                                 ["Import Developer ID certificate", signer, "Remove the signing keychain"])
                self.assertIn('          ./scripts/import-signing-certificate.sh "$KEYCHAIN_PATH"\n',
                              self.step(job, "Import Developer ID certificate"))
                self.assertIn('        run: ./scripts/remove-signing-keychain.sh "$KEYCHAIN_PATH" "$DEVELOPER_ID"\n',
                              self.step(job, "Remove the signing keychain"))
                # Only the signing step uses the keychain, and the notarization
                # credentials appear after it is gone.
                self.assertEqual([name for name, body in self.steps[job] if '--keychain "$KEYCHAIN_PATH"' in body], [signer])
                notarizer = next(name for name in names if name.startswith("Notarize "))
                self.assertGreater(names.index(notarizer), names.index("Remove the signing keychain"))
                self.assertEqual(names[-1], "Cleanup keychain")
                self.assertIn("        if: always()\n", self.step(job, "Cleanup keychain"))
        # By fingerprint, through the release signer; the disk image with one codesign call.
        sign = self.step("sign", "Sign the app")
        self.assertIn("/Developer ID Application/ && index($0, team) { print $2; exit }", sign)
        self.assertIn('python3 scripts/sign-desktop-app.py "$APP" --identity "$identity" \\\n'
                      '            --keychain "$KEYCHAIN_PATH" --entitlements desktop-app/resources/entitlements.mac.plist\n', sign)
        self.assertIn('codesign --sign "$identity" --keychain "$KEYCHAIN_PATH" --timestamp "Darkbloom-$VERSION-arm64.dmg"\n',
                      self.step("sign-dmg", "Sign the disk image"))
        for inline in ("security create-keychain", "security import", "security unlock-keychain", "set-key-partition-list",
                       "uuidgen", "cert.p12"):
            self.assertNotIn(inline, WORKFLOW)

    def test_npm_code_runs_only_in_jobs_without_a_secret(self):
        code = {name: without_comments(body) for name, body in self.jobs.items()}
        # Dependencies are installed from the lock file with install scripts off.
        self.assertEqual(re.findall(r"npm (?:ci|install|i)\b.*", without_comments(WORKFLOW)),
                         ["npm ci --ignore-scripts", "npm ci --ignore-scripts"])
        for name in ("build", "package"):
            self.assertIn("        run: npm ci --ignore-scripts\n", code[name])
        self.assertEqual([name for name in JOBS if "npm run dist" in code[name]], ["build"])
        self.assertEqual([name for name in JOBS if "electron-builder --config" in code[name]], ["package"])
        self.assertIn("--prepackaged \"$RUNNER_TEMP/app/Darkbloom.app\" --mac --publish never", code["package"])
        # No dependency cache carries files from another run into a release.
        self.assertNotIn("cache:", WORKFLOW)
        self.assertNotIn("actions/cache", WORKFLOW)
        for name in KEYED_JOBS + ("source", "publish"):
            with self.subTest(job=name):
                for npm in ("npm ", "npx", "node_modules", "electron-builder"):
                    self.assertNotIn(npm, code[name])
        # A release build is unsigned by configuration, with the feed embedded.
        for name in ("build", "package"):
            for setting in ("DARKBLOOM_DESKTOP_RELEASE: '1'", "DARKBLOOM_DESKTOP_UPDATE_URL: ${{ env.FEED_URL }}",
                            "CSC_IDENTITY_AUTO_DISCOVERY: 'false'"):
                self.assertIn(setting, code[name])

    def test_the_signing_jobs_run_no_built_code_and_only_first_party_node(self):
        for name in KEYED_JOBS:
            code = without_comments(self.jobs[name])
            # The app is signed, checked and archived as data; it is never started.
            for run in ("Contents/MacOS", "--ui-smoke-test"):
                self.assertNotIn(run, code, (name, run))
            self.assertNotRegex(code, r"(?m)^\s+(open|exec|sudo) ")
        self.assertNotIn("node", without_comments(self.jobs["sign"]).replace("setup-node", ""))
        # The disk image job runs Node for the feed script alone, after the key is gone.
        dmg = self.steps["sign-dmg"]
        node_steps = [name for name, body in dmg if re.search(r"(?m)^\s+node ", body)]
        self.assertEqual(node_steps, ["Staple the disk image and restamp the feed", "Verify the release"])
        names = self.names("sign-dmg")
        for name in node_steps:
            self.assertGreater(names.index(name), names.index("Remove the signing keychain"))
        self.assertEqual(sorted(set(re.findall(r'node "\$GITHUB_WORKSPACE/(\S+)"', self.jobs["sign-dmg"]))),
                         ["desktop-app/scripts/update-feed.mjs"])
        feed = (ROOT / "desktop-app/scripts/update-feed.mjs").read_text()
        imports = re.findall(r"(?m)^import .+ from '([^']+)';$", feed)
        self.assertTrue(imports)
        for module in imports:
            self.assertTrue(module.startswith("node:"), module)

    def test_every_hand_off_is_by_artifact_id_and_digest(self):
        expected = {"sign": [("build", "ARTIFACT")], "package": [("sign", "ARTIFACT")],
                    "sign-dmg": [("sign", "SIGNED"), ("package", "PACKAGED")], "publish": [("sign-dmg", "ARTIFACT")]}
        for job, sources in expected.items():
            with self.subTest(job=job):
                body = self.jobs[job]
                self.assertEqual(body.count(DOWNLOAD), len(sources))
                for producer, prefix in sources:
                    self.assertIn(f"          {prefix}_ID: ${{{{ needs.{producer}.outputs.artifact_id }}}}\n", body)
                    self.assertIn(f"          {prefix}_DIGEST: ${{{{ needs.{producer}.outputs.artifact_digest }}}}\n", body)
                    self.assertIn(f'--artifact-id "${prefix}_ID" --artifact-digest "${prefix}_DIGEST" \\\n'
                                  '            --run-id "$GITHUB_RUN_ID" --directory ', body)
        # Each producer names the artifact its own upload step created.
        for job, upload in (("build", "unsigned"), ("sign", "signed"), ("package", "packaged"), ("sign-dmg", "release")):
            with self.subTest(producer=job):
                self.assertIn(f"      artifact_id: ${{{{ steps.{upload}.outputs.artifact-id }}}}\n", self.jobs[job])
                self.assertIn(f"      artifact_digest: ${{{{ steps.{upload}.outputs.artifact-digest }}}}\n", self.jobs[job])
                self.assertEqual(self.jobs[job].count("actions/upload-artifact@"), 1)
        for by_name in ("download-artifact", "gh run download"):
            self.assertNotIn(by_name, WORKFLOW)
        self.assertIn("sha256sum --check --strict SHA256SUMS", self.jobs["publish"])

    def test_the_disk_image_is_signed_only_after_the_packages_are_checked(self):
        names = self.names("sign-dmg")
        check = "Check that the packages carry the signed app unchanged"
        self.assertLess(names.index(check), names.index("Import Developer ID certificate"))
        self.assertIn('"$GITHUB_WORKSPACE/scripts/check-desktop-packages.sh" "$RUNNER_TEMP/app/Darkbloom.app" \\\n'
                      '            "Darkbloom-$VERSION-arm64.zip" "Darkbloom-$VERSION-arm64.dmg" "$RUNNER_TEMP/checked"\n',
                      self.step("sign-dmg", check))
        script = (ROOT / "scripts/check-desktop-packages.sh").read_text()
        for rule in ('[[ "$(cdhash "$1")" == "$expected" ]]', "codesign --verify --deep --strict", "xcrun stapler validate",
                     '[[ "$(ls -A "$work/from-zip")" == Darkbloom.app ]]', '*) fail "Unexpected entry in the disk image: $entry" ;;'):
            self.assertIn(rule, script)
        # The layout files the npm-built packaging job wrote are plain files.
        self.assertIn('fail "Disk image entry $entry is not a regular file"', script)
        self.assertIn("fail 'Disk image entry .fseventsd holds something other than plain files'", script)
        # The image is detached, and a failed detach fails, before it is signed.
        self.assertTrue(script.rstrip().endswith('trap - EXIT\nhdiutil detach "$work/dmg" >/dev/null'))
        # The release that is verified and published is the checked copy.
        self.assertIn('APP="$RUNNER_TEMP/checked/from-zip/Darkbloom.app"', self.step("sign-dmg", "Verify the release"))

    def test_a_rerun_uploads_its_release_under_a_new_name(self):
        # "Re-run all jobs" uploads again; a fixed name would collide after the
        # disk image was notarized a second time.
        self.assertIn("          name: darkbloom-desktop-${{ needs.source.outputs.version }}-${{ github.run_attempt }}\n",
                      self.step("sign-dmg", "Retain the verified release"))

    def test_the_build_job_checks_the_signer_against_electron_builder(self):
        names = self.names("build")
        parity = "Check the release signer against electron-builder's on this app"
        self.assertLess(names.index("Build the unsigned app"), names.index(parity))
        self.assertLess(names.index(parity), names.index("Hand the unsigned app to the signing job"))
        body = self.step("build", parity)
        self.assertIn("DARKBLOOM_DESKTOP_UNSIGNED_APP: ${{ github.workspace }}/desktop-app/release/mac-arm64/Darkbloom.app", body)
        self.assertIn("        run: python3 scripts/test-sign-desktop-app.py\n", body)

    def test_no_check_is_the_first_half_of_an_and_list(self):
        # Under `set -e` a failing command before `&&` does not stop the script,
        # so a check written as `test A && test B` passes when A is false.
        for name, job in self.steps.items():
            for step_name, body in job:
                self.assertNotRegex(body, r"(?m)^\s+(test|\[) .*&& (test|\[) ", (name, step_name))
        for script in ("check-desktop-packages.sh", "notarize-artifact.sh", "import-signing-certificate.sh",
                       "remove-signing-keychain.sh"):
            self.assertNotRegex((ROOT / "scripts" / script).read_text(), r"(?m)^\s*(test|\[) .*&& (test|\[) ", script)

    def test_the_version_is_checked_before_it_reaches_a_file_name(self):
        version = self.step("source", "Resolve the version")
        self.assertIn(r'if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then', version)
        self.assertLess(version.index("=~ ^[0-9]+"), version.index('echo "version=$version" >> "$GITHUB_OUTPUT"'))
        self.assertIn('if [ "$GITHUB_REF_NAME" != "desktop-v$version" ]; then', version)
        # No workflow expression is pasted into a script: values arrive as environment variables.
        for name, job in self.steps.items():
            for step_name, body in job:
                run = body.split("        run:", 1)[1] if "        run:" in body else ""
                self.assertNotIn("${{", run, (name, step_name))


class NotarizeScriptTests(unittest.TestCase):
    XCRUN = r"""#!/bin/bash
printf '%s\n' "$*" >> "$STUB_LOG"
if [ "$2" = submit ]; then printf '%s' "$STUB_RESULT"; fi
if [ "$2" = log ]; then echo "apple log for $3"; fi
exit 0
"""

    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / "bin").mkdir()
        stub = self.root / "bin/xcrun"
        stub.write_text(self.XCRUN)
        stub.chmod(0o755)
        self.file = self.root / "Darkbloom.zip"
        self.file.write_bytes(b"zip")
        self.result = self.root / "notary.json"
        self.log = self.root / "xcrun.log"
        self.env = {"PATH": f"{self.root / 'bin'}:{os.environ['PATH']}", "STUB_LOG": str(self.log),
                    "APPLE_ID": "release@example.com", "APPLE_APP_PASSWORD": "app-password", "APPLE_TEAM_ID": "ABCDE12345"}

    def notarize(self, result=None, arguments=None, **env):
        env = {**self.env, "STUB_RESULT": json.dumps(result if result is not None else {}), **env}
        return subprocess.run(["bash", str(NOTARIZE), *(arguments or (str(self.file), str(self.result)))],
                              env=env, capture_output=True, text=True)

    def calls(self):
        return self.log.read_text().splitlines() if self.log.exists() else []

    def test_an_accepted_submission_passes_and_keeps_apples_answer(self):
        done = self.notarize({"id": "11111111-2222", "status": "Accepted"})
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(self.calls(), [f"notarytool submit {self.file} --apple-id release@example.com --password app-password "
                                        "--team-id ABCDE12345 --wait --timeout 30m --output-format json"])
        self.assertEqual(json.loads(self.result.read_text())["status"], "Accepted")
        self.assertNotIn("app-password", done.stdout + done.stderr)

    def test_any_other_verdict_fails_and_shows_apples_log(self):
        for result in ({"id": "11111111-2222", "status": "Invalid"}, {"id": "11111111-2222", "status": "In Progress"},
                       {"id": "11111111-2222"}, {"status": "Accepted "}, {}):
            with self.subTest(result=result):
                self.log.unlink(missing_ok=True)
                done = self.notarize(result)
                self.assertEqual(done.returncode, 1)
                self.assertIn("expected Accepted", done.stderr)
                logged = [call for call in self.calls() if call.startswith("notarytool log")]
                self.assertEqual(len(logged), 1 if result.get("id") else 0)
                if logged:
                    self.assertIn("apple log for 11111111-2222", done.stderr)

    def test_a_failing_submit_still_reports_the_verdict(self):
        stub = self.root / "bin/xcrun"
        stub.write_text(self.XCRUN.replace("exit 0", 'if [ "$2" = submit ]; then exit 1; fi\nexit 0'))
        done = self.notarize({"id": "11111111-2222", "status": "Invalid"})
        self.assertEqual(done.returncode, 1)
        self.assertIn("expected Accepted", done.stderr)
        self.assertIn("apple log for 11111111-2222", done.stderr)
        # No answer at all: still the verdict line, no log call.
        self.log.unlink(missing_ok=True)
        done = self.notarize(STUB_RESULT="")
        self.assertEqual(done.returncode, 1)
        self.assertIn("expected Accepted", done.stderr)

    def test_missing_credentials_or_file_stop_before_apple_is_called(self):
        for missing in ("APPLE_ID", "APPLE_APP_PASSWORD", "APPLE_TEAM_ID"):
            with self.subTest(missing=missing):
                done = self.notarize({"id": "1", "status": "Accepted"}, **{missing: ""})
                self.assertEqual(done.returncode, 1)
                self.assertIn("not configured", done.stderr)
        self.assertEqual(self.notarize(arguments=(str(self.root / "missing.zip"), str(self.result))).returncode, 2)
        self.assertEqual(self.notarize(arguments=(str(self.file),)).returncode, 2)
        self.assertEqual(self.calls(), [])


if __name__ == "__main__":
    unittest.main()
