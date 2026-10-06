#!/usr/bin/env python3
"""Exercise the real installer setup function with all OS/network effects mocked."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class InstallerOnboardingTests(unittest.TestCase):
    def run_setup(self, version, enrolled=False, request_fails=False, interactive=False):
        source = (Path(__file__).resolve().parent / "install.sh").read_text()
        start = source.index("configure_device_verification() {")
        end = source.index("\n}\n", start) + 3
        with tempfile.TemporaryDirectory() as directory:
            trace = Path(directory) / "calls"
            script = source[start:end] + r'''
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
configure_device_verification
echo "next installation phase"
'''
            result = subprocess.run(
                ["bash", "-eu", "-o", "pipefail", "-c", script],
                env={**os.environ, "MACOS": version,
                     "INTERACTIVE": "true" if interactive else "false",
                     "COORD_URL": "https://coordinator.invalid",
                     "ONBOARDING_TRACE": str(trace), "ONBOARDING_TMP": directory,
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

    def test_legacy_setup_never_attempts_anonymous_enrollment_or_fallback(self):
        output, calls = self.run_setup("26.5", request_fails=True)
        self.assertEqual(calls, "profiles\n")
        self.assertNotIn("coordinator unreachable", output)
        self.assertNotIn("Enrollment verified", output)


if __name__ == "__main__":
    unittest.main()
