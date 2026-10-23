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
    def run_setup(self, version, enrolled=False, request_fails=False, interactive=False,
                  release="0.9.20"):
        source = (Path(__file__).resolve().parent / "install.sh").read_text()

        def function(name):
            start = source.index(name + "() {")
            return source[start:source.index("\n}\n", start) + 3]

        def constant(name):
            for line in source.splitlines():
                if line.startswith(name + "="):
                    return line + "\n"
            raise AssertionError(f"{name} not found in install.sh")

        with tempfile.TemporaryDirectory() as directory:
            trace = Path(directory) / "calls"
            # select_provider_identity reads the designated-requirement constants
            # to pick the per-identity signature requirement, so define them here.
            script = (constant("DARKBLOOM_DESIGNATED_REQUIREMENT")
                      + constant("DARKBLOOM_PRERELEASE_DESIGNATED_REQUIREMENT")
                      + function("select_provider_identity")
                      + function("configure_device_verification")) + r'''
profiles() {
    echo profiles >> "$ONBOARDING_TRACE"
    if [ "$ONBOARDING_ENROLLED" = yes ]; then
        echo "MDM enrollment: Yes"
    else
        echo "MDM enrollment: No"
    fi
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
                     "ONBOARDING_ENROLLED": "yes" if enrolled else "no",
                     "ONBOARDING_REQUEST_FAILS": "yes" if request_fails else "no"},
                input="", capture_output=True, text=True, check=True, timeout=5)
            self.assertIn("next installation phase", result.stdout)
            return result.stdout, trace.read_text() if trace.exists() else ""

    def test_macos27_never_requests_or_opens_mdm_even_when_unavailable(self):
        for version in ("27", "27.0", "27.1", "28.0"):
            for enrolled in (False, True):
                with self.subTest(version=version, enrolled=enrolled):
                    output, calls = self.run_setup(version, enrolled, request_fails=True)
                    self.assertEqual(calls, "")
                    self.assertIn("App Attest without Darkbloom MDM", output)
                    self.assertIn("only after the coordinator approves", output)
                    self.assertIn("deactivated soon", output)

    def test_older_macos_defers_signed_enrollment_until_existing_account_login(self):
        for version in ("14.7", "26.5.2"):
            for interactive in (False, True):
                with self.subTest(version=version, interactive=interactive):
                    output, calls = self.run_setup(version, interactive=interactive)
                    self.assertEqual(calls, "profiles\n")
                    self.assertIn("Upgrade to macOS 27", output)
                    self.assertIn("deactivated soon", output)
                    self.assertIn("existing account", output)
                    self.assertLess(output.index("darkbloom login"), output.index("darkbloom enroll"))
                    self.assertIn("signed eligibility", output)
                    self.assertIn("New providers require macOS 27+", output)
                    self.assertIn("without base rewards", output)
                    self.assertIn("All base rewards require macOS 27+", output)

    def test_existing_management_is_preserved(self):
        output, calls = self.run_setup("26.5", enrolled=True)
        self.assertEqual(calls, "profiles\n")
        self.assertIn("keep existing management", output)
        self.assertNotIn("Already enrolled ✓", output)

    def test_unknown_os_does_not_guess_legacy_enrollment(self):
        for version in ("?", "", "unknown"):
            output, calls = self.run_setup(version)
            self.assertEqual(calls, "")
            self.assertIn("no MDM profile was downloaded", output)
            self.assertLess(output.index("darkbloom login"), output.index("darkbloom enroll"))

    def test_dev_release_names_the_dev_cli(self):
        for version in ("27.0", "26.5"):
            with self.subTest(version=version):
                output, _ = self.run_setup(version, release=DEV_RELEASE)
                self.assertIn(identity(DEV_RELEASE)["cliName"] + " login", output)
                self.assertNotIn(identity("0.9.20")["cliName"] + " login", output)

    def test_staging_release_names_the_staging_cli(self):
        for version in ("27.0", "26.5"):
            with self.subTest(version=version):
                output, _ = self.run_setup(version, release=STAGING_RELEASE)
                self.assertIn(identity(STAGING_RELEASE)["cliName"] + " login", output)
                self.assertNotIn(identity("0.9.20")["cliName"] + " login", output)

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

        def constant(name):
            for line in source.splitlines():
                if line.startswith(name + "="):
                    return line + "\n"
            raise AssertionError(f"{name} not found in install.sh")

        with tempfile.TemporaryDirectory() as home:
            # select_provider_identity reads the designated-requirement constants.
            script = (constant("DARKBLOOM_DESIGNATED_REQUIREMENT")
                      + constant("DARKBLOOM_PRERELEASE_DESIGNATED_REQUIREMENT")
                      + function("select_provider_identity")
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
        self.assertIn("Upgrade to macOS 27 or later to keep serving", result.stdout)
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
