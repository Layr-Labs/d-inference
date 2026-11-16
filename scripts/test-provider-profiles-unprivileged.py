#!/usr/bin/env python3
"""The provider reads MDM enrollment only unprivileged and manages no profile.

Darkbloom MDM is removed. The provider may read the device's MDM enrollment
state without privileges (`profiles status -type enrollment`) to tell an
operator that an old Darkbloom profile can be removed, and open System
Settings at it. It runs no other `profiles` command and never hands
`profiles` to `sudo`: macOS lets only the user remove a profile.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "provider-swift" / "Sources"
READER = "provider-swift/Sources/ProviderCore/Security/MDMEnrollment.swift"


def swift_sources():
    return {str(p.relative_to(ROOT)): p.read_text() for p in sorted(SOURCES.rglob("*.swift"))}


class ProviderProfilesTests(unittest.TestCase):
    def test_only_the_enrollment_reader_runs_profiles(self):
        users = [path for path, text in swift_sources().items() if "/usr/bin/profiles" in text]
        self.assertEqual(users, [READER])

    def test_profiles_runs_only_the_unprivileged_status_read(self):
        text = swift_sources()[READER]
        self.assertNotIn('"/usr/bin/sudo"', text)
        calls = re.findall(r'"/usr/bin/profiles",\s*(\[[^\]]*\])', text)
        self.assertEqual(calls, ['["status", "-type", "enrollment"]'])


if __name__ == "__main__":
    unittest.main()
