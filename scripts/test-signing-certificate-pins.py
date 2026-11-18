#!/usr/bin/env python3
"""Check that every signature check accepts exactly the listed Darkbloom signing certificates.

DarkbloomSigningIdentity.certificateSHA1s in provider-swift is the list. The
installer, the desktop app, the release workflows and the documented check
commands each hold a copy of the requirement built from it, and an installed
copy cannot be changed later: a copy that lacks a certificate refuses that
certificate's builds, and a copy that names an extra one accepts builds
Darkbloom did not sign.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parent.parent
SOURCES = ROOT / "provider-swift/Sources"
IDENTITY = (SOURCES / "DarkbloomSigningIdentity/DarkbloomSigningIdentity.swift").read_text()
TEAM = re.search(r'public static let teamID = "([A-Z0-9]{10})"', IDENTITY).group(1)
LISTED = re.search(r"certificateSHA1s = \[\n(.*?)\n    \]", IDENTITY, re.S).group(1)
PINS = re.findall(r'^\s*"([0-9a-f]{40})",$', LISTED, re.M)
ALTERNATIVES = [f'certificate leaf = H"{pin}"' for pin in PINS]
# The rule of DarkbloomSigningIdentity.certificateClause.
CLAUSE = ALTERNATIVES[0] if len(ALTERNATIVES) == 1 else "(" + " or ".join(ALTERNATIVES) + ")"
TEAM_CLAUSE = f'certificate leaf[subject.OU] = "{TEAM}"'


def requirement(identifier):
    return f'anchor apple generic and identifier "{identifier}" and {TEAM_CLAUSE} and {CLAUSE}'


def stopping_at_the_team(text):
    """The lines of text whose requirement names the team and not the listed certificates."""
    return [line for line in text.splitlines()
            if "certificate leaf[subject.OU]" in line and CLAUSE not in line]


class SigningCertificatePinTests(unittest.TestCase):
    def test_the_list_is_distinct_lowercase_sha1_values(self):
        self.assertTrue(PINS)
        self.assertEqual(len(set(PINS)), len(PINS))
        # Every quoted value in the list was read: none is malformed.
        self.assertEqual(len(re.findall(r'"[^"]*"', LISTED)), len(PINS))

    def test_swift_builds_the_requirement_this_test_expects(self):
        for part in ('"anchor apple generic and identifier \\"\\(identifier)\\" "',
                     '+ "and certificate leaf[subject.OU] = \\"\\(teamID)\\" "',
                     '+ "and \\(certificateClause(certificateSHA1s))"',
                     'let pins = sha1s.map { "certificate leaf = H\\"\\($0)\\"" }',
                     'return pins.count == 1 ? pins[0] : "(" + pins.joined(separator: " or ") + ")"'):
            self.assertIn(part, IDENTITY)

    def test_installer_requires_a_listed_certificate(self):
        installer = (ROOT / "scripts/install.sh").read_text()
        lines = installer.splitlines()
        self.assertIn("DARKBLOOM_DESIGNATED_REQUIREMENT='" + requirement("io.darkbloom.provider") + "'", lines)
        self.assertIn("DARKBLOOM_FAN_HELPER_REQUIREMENT='" + requirement("io.darkbloom.fan-helper") + "'", lines)
        self.assertEqual(stopping_at_the_team(installer), [])

    def test_desktop_app_requires_a_listed_certificate_of_the_cli_it_runs(self):
        backend = (ROOT / "desktop-app/src/main/backend.ts").read_text()
        self.assertIn("'-R=" + requirement("io.darkbloom.provider") + "';", backend)
        self.assertEqual(stopping_at_the_team(backend), [])

    def test_documented_check_commands_require_a_listed_certificate(self):
        # Operators paste these; a command that stops at the team would report
        # "signature OK" for a build Darkbloom did not sign.
        for name in ("installation.md", "agent-setup.md"):
            with self.subTest(doc=name):
                doc = (ROOT / "docs/provider" / name).read_text()
                self.assertIn("-R='" + requirement("io.darkbloom.provider") + "' \\\n", doc)
                self.assertEqual(stopping_at_the_team(doc), [])

    def test_reference_rows_name_exactly_the_listed_certificates(self):
        for path, row in (("docs/operations/provider-release.md", "| Listed |"),
                          ("docs/provider/cli-reference.md", "| Signing certificates |")):
            with self.subTest(doc=path):
                rows = [line for line in (ROOT / path).read_text().splitlines() if line.startswith(row)]
                self.assertEqual(len(rows), 1)
                self.assertEqual(re.findall(r"`([0-9a-f]{40})`", rows[0]), PINS)

    def test_release_workflows_verify_against_the_list(self):
        for name in ("release-provider.yml", "provider-signing-validation.yml"):
            with self.subTest(workflow=name):
                workflow = (ROOT / ".github/workflows" / name).read_text()
                self.assertEqual(
                    re.findall(r"^\s+SIGNING_CERTIFICATE_REQUIREMENT: '(.*)'$", workflow, re.M), [CLAUSE])
                self.assertEqual(re.findall(r"^\s+APPLE_TEAM_ID: '?([^'\n]*)'?$", workflow, re.M), [TEAM])
                # No requirement in the workflow stops at the team.
                requirements = [line for line in workflow.splitlines() if "certificate leaf[subject.OU]" in line]
                self.assertTrue(requirements)
                for line in requirements:
                    self.assertTrue(
                        line.rstrip(' \\').endswith('\\"$APPLE_TEAM_ID\\" and $SIGNING_CERTIFICATE_REQUIREMENT"'),
                        line)

    def test_only_the_recorded_swift_checks_build_their_own_requirement(self):
        # A check that names the team itself bypasses the certificate list.
        # The ones that do have their own identity rule:
        #   AddonPeerPolicy: the Sandbox add-on is another product with its own
        #     signing certificate, so the provider's list does not apply to it.
        #   WorkerPeerIdentity: the App Attest worker must have this process's
        #     own code hash, which is stricter than any certificate.
        #   DistributedInstalledHelperSignature: a cluster helper must carry this
        #     process's own leaf certificate (#2246), which the list already
        #     admitted when this provider was installed or updated.
        own_rule = {"ProviderCore/Addon/AddonPeerPolicy.swift",
                    "ProviderAppAttest/Worker/WorkerPeerIdentity.swift",
                    "ProviderCore/Inference/Distributed/Installed/DistributedInstalledHelperSignature.swift"}
        naming_team = {str(path.relative_to(SOURCES)) for path in SOURCES.rglob("*.swift")
                       if "subject.OU" in path.read_text(errors="replace")}
        self.assertEqual(naming_team, own_rule | {"DarkbloomSigningIdentity/DarkbloomSigningIdentity.swift"})


if __name__ == "__main__":
    unittest.main()
