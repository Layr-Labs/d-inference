#!/usr/bin/env python3
"""Exercise the real installer setup function with all OS/network effects mocked."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from provider_release_identity import DOCUMENT, identity

DEV_RELEASE = "0.9.20" + DOCUMENT["releaseVersionMarkers"]["dev"] + "12"
STAGING_RELEASE = "0.9.20" + DOCUMENT["releaseVersionMarkers"]["staging"] + "12"


class InstallerOnboardingTests(unittest.TestCase):
    def run_setup(self, version, enrolled="none", request_fails=False, interactive=False,
                  release="0.9.20"):
        source = (Path(__file__).resolve().parent / "install.sh").read_text()

        def function(name):
            start = source.index(name + "() {")
            return source[start:source.index("\n}\n", start) + 3]

        with tempfile.TemporaryDirectory() as directory:
            trace = Path(directory) / "calls"
            script = (function("select_provider_identity")
                      + function("configure_device_verification")
                      + function("retired_darkbloom_profile_installed")) + r'''
PROFILES=profiles
profiles() {
    echo profiles >> "$ONBOARDING_TRACE"
    case "$ONBOARDING_ENROLLED" in
        none) printf 'Enrolled via DEP: No\nMDM enrollment: No\n' ;;
        company) printf 'Enrolled via DEP: Yes\nMDM enrollment: Yes\nMDM server: https://corp.example/mdm\n' ;;
        darkbloom) printf 'Enrolled via DEP: No\nMDM enrollment: Yes (User Approved)\nMDM server: https://api.darkbloom.dev/mdm/connect\n' ;;
        garbled) printf 'Enrolled via DEP: No\nMDM enrollment: Yes (User Approved)\n' ;;
        *) printf 'Enrolled via DEP: No\nMDM enrollment: Yes (User Approved)\nMDM server: %s\n' "$ONBOARDING_ENROLLED" ;;
    esac
}
curl() {
    echo "curl $*" >> "$ONBOARDING_TRACE"
    [ "$ONBOARDING_REQUEST_FAILS" = no ]
}
mktemp() { echo "$ONBOARDING_TMP"; }
open() { echo "open $*" >> "$ONBOARDING_TRACE"; }
sleep() { :; }
select_provider_identity "$ONBOARDING_RELEASE"
configure_device_verification
echo "next installation phase"
'''
            result = subprocess.run(
                ["bash", "-eu", "-o", "pipefail", "-c", script],
                env={**os.environ, "MACOS": version,
                     "INTERACTIVE": "true" if interactive else "false",
                     "COORD_URL": "https://coordinator.invalid",
                     "ONBOARDING_TRACE": str(trace), "ONBOARDING_TMP": directory,
                     "ONBOARDING_RELEASE": release,
                     "ONBOARDING_ENROLLED": enrolled,
                     "ONBOARDING_REQUEST_FAILS": "yes" if request_fails else "no"},
                input="", capture_output=True, text=True, check=True, timeout=5)
            self.assertIn("next installation phase", result.stdout)
            return result.stdout, trace.read_text() if trace.exists() else ""

    def test_setup_never_downloads_or_opens_a_profile(self):
        for version in ("14.7", "26.5.2", "27", "27.0", "27.1", "28.0", "?", "", "unknown"):
            for enrolled in ("none", "darkbloom", "company"):
                with self.subTest(version=version, enrolled=enrolled):
                    output, calls = self.run_setup(version, enrolled, request_fails=True)
                    self.assertEqual(calls, "profiles\n")
                    self.assertIn("App Attest only, which needs macOS 27 or later", output)
                    if enrolled != "darkbloom":
                        self.assertNotIn("MDM", output)
                    self.assertNotIn("darkbloom enroll", output)
                    self.assertNotIn("grandfathered", output)
                    self.assertNotIn("deactivated soon", output)

    def test_macos27_starts_with_app_attest(self):
        for version in ("27", "27.1", "28.0"):
            with self.subTest(version=version):
                output, _ = self.run_setup(version)
                self.assertLess(output.index("darkbloom login"), output.index("darkbloom start"))
                self.assertIn("authorizes this connection with App Attest", output)

    def test_older_macos_is_told_to_update_to_serve(self):
        for version in ("14.7", "26.5.2"):
            for interactive in (False, True):
                with self.subTest(version=version, interactive=interactive):
                    output, _ = self.run_setup(version, interactive=interactive)
                    self.assertIn(f"runs macOS {version} and cannot serve", output)
                    self.assertIn("Software Update", output)

    def test_only_this_installs_darkbloom_profile_gets_the_removal_line(self):
        # The provider's rule (parseMDMEnrollmentStatus): this environment's host or a
        # *.darkbloom.dev / *.darkbloom.ai host that is not another environment's.
        ours = ("darkbloom", "https://API.Darkbloom.dev/mdm/connect", "https://mdm.darkbloom.ai/mdm/connect",
                "https://api.darkbloom.dev:443/mdm/connect", "HTTPS://api.darkbloom.dev/mdm/connect",
                "https://user@api.darkbloom.dev/mdm/connect")
        foreign = ("none", "company", "https://api.dev.darkbloom.xyz/mdm/connect", "garbled",
                   "https://x@api.dev.darkbloom.dev/mdm/connect",
                   "https://api.dev.darkbloom.dev/mdm/connect", "https://api.staging.darkbloom.dev/mdm/connect",
                   "https://x.darkbloom.example.com/mdm/connect", "https://darkbloom.dev.evil.example/mdm",
                   "http://api.darkbloom.dev/mdm/connect")
        for enrolled in ours:
            with self.subTest(enrolled=enrolled):
                output, _ = self.run_setup("27.0", enrolled)
                self.assertIn("old Darkbloom MDM profile is no longer used", output)
                self.assertIn("darkbloom unenroll and choose 2", output)
                self.assertIn("employer or school", output)
        for enrolled in foreign:
            with self.subTest(enrolled=enrolled):
                output, _ = self.run_setup("27.0", enrolled)
                self.assertNotIn("unenroll", output)

    def test_the_staging_installer_claims_only_the_staging_profile(self):
        output, _ = self.run_setup("27.0", "https://api.staging.darkbloom.dev/mdm/connect", release=STAGING_RELEASE)
        self.assertIn(identity(STAGING_RELEASE)["cliName"] + " unenroll and choose 2", output)
        output, _ = self.run_setup("27.0", "darkbloom", release=STAGING_RELEASE)
        self.assertNotIn("unenroll", output)

    def test_the_installer_hosts_are_the_identity_hosts(self):
        source = (Path(__file__).resolve().parent / "install.sh").read_text()
        body = source[source.index("retired_darkbloom_profile_installed() {"):]
        body = body[:body.index("\n}\n")]
        for environment in DOCUMENT["environments"].values():
            host = environment["coordinatorHTTPURL"].split("://", 1)[1].split("/", 1)[0]
            self.assertIn(environment["cliName"] if environment["cliName"] != "darkbloom" else "*)", body)
            self.assertIn(host, body)

    def test_the_dev_installer_claims_only_the_devnet_profile(self):
        output, _ = self.run_setup("27.0", "https://api.dev.darkbloom.dev/mdm/connect", release=DEV_RELEASE)
        self.assertIn(identity(DEV_RELEASE)["cliName"] + " unenroll and choose 2", output)
        output, _ = self.run_setup("27.0", "darkbloom", release=DEV_RELEASE)
        self.assertNotIn("unenroll", output)

    def test_dev_release_names_the_dev_cli(self):
        for version in ("27.0", "26.5"):
            with self.subTest(version=version):
                output, _ = self.run_setup(version, release=DEV_RELEASE)
                cli = identity(DEV_RELEASE)["cliName"]
                self.assertIn(cli + (" login" if version.startswith("27") else " restart"), output)
                self.assertNotIn(identity("0.9.20")["cliName"] + " ", output)

    def test_staging_release_names_the_staging_cli(self):
        for version in ("27.0", "26.5"):
            with self.subTest(version=version):
                output, _ = self.run_setup(version, release=STAGING_RELEASE)
                cli = identity(STAGING_RELEASE)["cliName"]
                self.assertIn(cli + (" login" if version.startswith("27") else " restart"), output)
                self.assertNotIn(identity("0.9.20")["cliName"] + " ", output)

    def test_legacy_setup_never_attempts_anonymous_enrollment_or_fallback(self):
        output, calls = self.run_setup("26.5", request_fails=True)
        self.assertEqual(calls, "profiles\n")
        self.assertNotIn("coordinator unreachable", output)
        self.assertNotIn("Enrollment verified", output)


class SupportedMacOSTests(unittest.TestCase):
    """New providers need macOS 27+; an existing install can still be updated or repaired."""

    def run_check(self, version, existing=False, release="0.9.20"):
        source = (Path(__file__).resolve().parent / "install.sh").read_text()

        def function(name):
            start = source.index(name + "() {")
            return source[start:source.index("\n}\n", start) + 3]

        with tempfile.TemporaryDirectory() as home:
            script = (function("select_provider_identity")
                      + function("require_supported_macos")) + r'''
select_provider_identity "$CHECK_RELEASE"
if [ "$CHECK_EXISTING" = yes ]; then mkdir -p "$BIN_DIR" && : > "$BIN_DIR/$CLI_NAME"; fi
require_supported_macos
echo "installation continues"
'''
            return subprocess.run(
                ["bash", "-eu", "-o", "pipefail", "-c", script],
                env={**os.environ, "HOME": home, "MACOS": version, "CHECK_RELEASE": release,
                     "CHECK_EXISTING": "yes" if existing else "no"},
                capture_output=True, text=True, timeout=5)

    def test_new_provider_on_older_macos_is_refused_with_an_upgrade_prompt(self):
        for version in ("26.5.2", "15.6", "14.7"):
            with self.subTest(version=version):
                result = self.run_check(version)
                self.assertEqual(result.returncode, 1)
                self.assertNotIn("installation continues", result.stdout)
                self.assertIn("needs macOS 27 or later for new providers", result.stderr)
                self.assertIn("Software Update", result.stderr)

    def test_existing_install_on_older_macos_can_still_update(self):
        result = self.run_check("26.5.2", existing=True)
        self.assertEqual(result.returncode, 0)
        self.assertIn("installation continues", result.stdout)
        self.assertIn("update to macOS 27 or later to serve", result.stdout)
        dev = self.run_check("26.5.2", existing=False, release=DEV_RELEASE)
        self.assertEqual(dev.returncode, 1, "a production install does not grandfather the dev CLI")

    def test_macos27_and_unknown_versions_continue(self):
        for version in ("27", "27.0", "28.1", "?", ""):
            with self.subTest(version=version):
                result = self.run_check(version)
                self.assertEqual(result.returncode, 0)
                self.assertIn("installation continues", result.stdout)
                self.assertEqual(result.stderr, "")


if __name__ == "__main__":
    unittest.main()
