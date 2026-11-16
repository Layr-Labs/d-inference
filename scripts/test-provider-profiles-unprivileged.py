#!/usr/bin/env python3
"""Regression check: the provider reads MDM enrollment only unprivileged.

Darkbloom MDM is removed. The provider may read the device's MDM enrollment
state without privileges (`profiles status -type enrollment`) to tell an
operator that an old Darkbloom profile can be removed, and open System
Settings at it. It runs no other `profiles` command and never hands
`profiles` to `sudo` or an administrator AppleScript: macOS lets only the user
remove a profile. This guards against accidental regressions; it is a source
scan, not a proof against deliberate obfuscation.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "provider-swift" / "Sources"
READER = "provider-swift/Sources/ProviderCore/Security/MDMEnrollment.swift"
# A Swift string literal on one line (multi-line literals hold no paths here).
LITERAL = re.compile(r'"((?:[^"\\\n]|\\.)*)"')
# A literal that names the profiles command: the bare word, a command line
# starting with it, or any path ending in it.
NAMES_PROFILES = re.compile(r'^profiles(\s|$)|/+profiles(\s|$|")|\bshell script\b.*\bprofiles\b', re.I)


def swift_sources():
    return {str(p.relative_to(ROOT)): p.read_text() for p in sorted(SOURCES.rglob("*.swift"))}


class ProviderProfilesTests(unittest.TestCase):
    def test_the_reader_runs_only_the_unprivileged_status_read(self):
        text = swift_sources()[READER]
        self.assertEqual(text.count('"/usr/bin/profiles"'), 1)
        calls = re.findall(r'"/usr/bin/profiles",\s*(\[[^\]]*\])', text)
        self.assertEqual(calls, ['["status", "-type", "enrollment"]'])
        for word in ('"/usr/bin/sudo"', "osascript", "administrator privileges", "do shell script"):
            self.assertNotIn(word, text)

    def test_only_the_reader_names_the_profiles_command_and_only_once(self):
        offenders, reader_hits = [], []
        for path, text in swift_sources().items():
            for number, line in enumerate(text.splitlines(), 1):
                for literal in LITERAL.findall(line):
                    if NAMES_PROFILES.search(literal):
                        hit = f"{path}:{number}: {literal}"
                        if path == READER and literal == "/usr/bin/profiles":
                            reader_hits.append(hit)
                        elif not (path == READER and literal.startswith("profiles status ")):
                            offenders.append(hit)  # the reader's log text names the status read
                if 'appendingPathComponent("profiles")' in line:
                    offenders.append(f"{path}:{number}: appendingPathComponent")
        self.assertEqual(offenders, [])
        self.assertEqual(len(reader_hits), 1, reader_hits)


if __name__ == "__main__":
    unittest.main()
