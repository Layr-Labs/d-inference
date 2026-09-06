#!/usr/bin/env python3
"""Synthetic metadata/lifecycle tests: no secrets, real keychains or app execution."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock

import provider_signing_identity as identity

TEAM = "SLDQ2GJ6TL"
HASH = "A" * 40
NAME = "Developer ID Application: A Different Legal Display Name, Inc. (" + TEAM + ")"


def listing(name=NAME, fingerprint=HASH):
    return '  1) ' + fingerprint + ' "' + name + '"\n     1 valid identities found\n'


class FakeSecurity:
    def __init__(self, keychains, text=None):
        self.current = list(keychains)
        self.text = listing() if text is None else text
        self.calls = []
        self.fail_restore = False
        self.original = list(keychains)

    def __call__(self, *args):
        self.calls.append(args)
        if args == ("list-keychains", "-d", "user"):
            return "\n".join(json.dumps(path) for path in self.current)
        if args[:4] == ("list-keychains", "-d", "user", "-s"):
            if self.fail_restore and list(args[4:]) == self.original:
                raise subprocess.CalledProcessError(1, ["security", *args])
            self.current = list(args[4:])
            return ""
        if args[:4] == ("find-identity", "-v", "-p", "codesigning"):
            if len(args) != 5: raise AssertionError("identity lookup was not keychain-scoped")
            return self.text
        if args[0] == "delete-keychain":
            Path(args[1]).unlink()
            self.current = [value for value in self.current if value != args[1]]
            return ""
        raise AssertionError("unexpected security command: " + repr(args))


class SigningIdentityTests(unittest.TestCase):
    def test_unique_valid_developer_id_uses_fingerprint_without_company_name_pin(self):
        rows = identity.parse_valid_identities(listing(fingerprint=HASH.lower()))
        self.assertEqual(identity.select_identity(rows, TEAM), {"sha1": HASH, "name": NAME})
        requirement = identity.code_requirement(TEAM)
        self.assertIn("anchor apple generic", requirement)
        self.assertIn("certificate leaf[field.1.2.840.113635.100.6.1.13] exists", requirement)
        self.assertIn('certificate leaf[subject.OU] = "' + TEAM + '"', requirement)

    def test_zero_ambiguous_wrong_team_and_wrong_kind_fail_closed(self):
        cases = [[], [{"sha1": HASH, "name": NAME}, {"sha1": "B" * 40, "name": NAME}],
                 [{"sha1": HASH, "name": NAME.replace(TEAM, "OTHERTEAM1")}],
                 [{"sha1": HASH, "name": "Apple Development: Person (" + TEAM + ")"}],
                 [{"sha1": HASH, "name": "Developer ID Installer: Org (" + TEAM + ")"}]]
        for rows in cases:
            with self.subTest(rows=rows), self.assertRaises(ValueError): identity.select_identity(rows, TEAM)

    def test_malformed_invalid_or_inconsistent_listings_are_not_ignored(self):
        invalid = [listing().replace(HASH, "not-a-fingerprint"), listing().replace("1 valid", "2 valid"),
                   listing().replace('"\n', '" (CSSMERR_TP_CERT_EXPIRED)\n'),
                   listing() + "unexpected trailing line\n", listing().replace("1)", "2)"),
                   listing().replace("Different", "Different\x1b[31m"),
                   '1) ' + HASH + ' "' + NAME + '"\n2) ' + HASH + ' "' + NAME + '"\n2 valid identities found\n']
        for text in invalid:
            with self.subTest(text=text), self.assertRaises(ValueError): identity.parse_valid_identities(text)
        self.assertEqual(identity.parse_valid_identities("0 valid identities found\n"), [])

    def test_quoted_search_paths_are_preserved_without_shell_splitting(self):
        value = '    "/Users/runner/Library/Keychains/login.keychain-db"\n    "/tmp/Path With Spaces/other.keychain-db"\n'
        self.assertEqual(identity.search_list(value), ["/Users/runner/Library/Keychains/login.keychain-db",
                                                     "/tmp/Path With Spaces/other.keychain-db"])
        for text in ['"relative.keychain-db"', '"/tmp/a"\n"/tmp/a"']:
            with self.assertRaises(ValueError): identity.search_list(text)

    def test_capture_activate_select_and_cleanup_restore_exact_original_order(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); keychain = root / identity.KEYCHAIN_NAME
            snap, out, env = root / "snapshot.json", root / "identity.json", root / "env"
            original = ["/Users/runner/Library/Keychains/login.keychain-db", "/tmp/Other Keys/custom.keychain-db"]
            fake = FakeSecurity(original)
            with mock.patch.object(identity, "security", side_effect=fake):
                identity.capture_search_list(snap, keychain)
                keychain.write_text("synthetic placeholder, not a keychain")
                identity.activate_search_list(snap)
                self.assertEqual(fake.current, [str(keychain), *original])
                identity.record_identity(snap, TEAM, out, env)
                self.assertEqual(json.loads(out.read_text())["selected"]["sha1"], HASH)
                self.assertEqual(env.read_text(), "SIGNING_IDENTITY_SHA1=" + HASH + "\nSIGNING_REQUIREMENT="
                                 + identity.code_requirement(TEAM) + "\n")
                for name in ["signing-certificate.p12", "profile.plist"]: (root / name).write_text("synthetic")
                identity.cleanup_keychain(snap, root / "cleanup.json")
                identity.cleanup_keychain(snap, root / "cleanup.json")
                self.assertEqual(fake.current, original)
                self.assertFalse(keychain.exists())
                self.assertFalse((root / "signing-certificate.p12").exists())
                self.assertFalse((root / "profile.plist").exists())
                receipt = json.loads((root / "cleanup.json").read_text())
                self.assertEqual(receipt["status"], "cleaned")
                self.assertTrue(receipt["search_list_restored"])
                self.assertIn(("find-identity", "-v", "-p", "codesigning", str(keychain)), fake.calls)

    def test_rejected_identity_writes_diagnostics_without_exporting_a_fallback(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); keychain = root / identity.KEYCHAIN_NAME; snap = root / "snapshot.json"
            fake = FakeSecurity([], "0 valid identities found\n")
            with mock.patch.object(identity, "security", side_effect=fake):
                identity.capture_search_list(snap, keychain); keychain.write_text("synthetic")
                identity.activate_search_list(snap)
                with self.assertRaises(ValueError):
                    identity.record_identity(snap, TEAM, root / "identity.json", root / "env")
                self.assertFalse((root / "env").exists())
                self.assertEqual(json.loads((root / "identity.json").read_text())["status"], "rejected")
                identity.cleanup_keychain(snap, root / "cleanup.json")
                self.assertEqual(fake.current, [])

    def test_restore_failure_still_deletes_owned_material_and_fails_cleanup(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); keychain = root / identity.KEYCHAIN_NAME; snap = root / "snapshot.json"
            fake = FakeSecurity(["/tmp/original.keychain-db"])
            with mock.patch.object(identity, "security", side_effect=fake):
                identity.capture_search_list(snap, keychain); keychain.write_text("synthetic")
                identity.activate_search_list(snap)
                (root / "signing-certificate.p12").write_text("synthetic")
                fake.fail_restore = True
                with self.assertRaises(ValueError): identity.cleanup_keychain(snap, root / "cleanup.json")
                self.assertFalse(keychain.exists())
                self.assertFalse((root / "signing-certificate.p12").exists())
                receipt = json.loads((root / "cleanup.json").read_text())
                self.assertEqual(receipt["status"], "failed")
                self.assertFalse(receipt["search_list_restored"])
                self.assertTrue(receipt["temporary_keychain_deleted"])

    def test_absent_snapshot_does_not_touch_keychains_and_capture_refuses_reuse(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); keychain = root / identity.KEYCHAIN_NAME; snap = root / "snapshot.json"
            fake = FakeSecurity([])
            with mock.patch.object(identity, "security", side_effect=fake):
                identity.cleanup_keychain(snap, root / "cleanup.json")
                self.assertEqual(fake.calls, [])
                keychain.write_text("preexisting synthetic fixture")
                with self.assertRaises(ValueError): identity.capture_search_list(snap, keychain)
                self.assertFalse(snap.exists())
                self.assertTrue(keychain.exists())

    @unittest.skipUnless(shutil.which("csreq"), "Apple csreq is unavailable")
    def test_apple_requirement_parser_accepts_team_kind_and_identifier_bindings(self):
        with tempfile.TemporaryDirectory() as tmp:
            for index, suffix in enumerate(["", ' and identifier "io.darkbloom.provider"',
                                            ' and identifier "io.darkbloom.fan-helper"']):
                output = Path(tmp) / str(index)
                result = subprocess.run(["csreq", "-r-", "-b", str(output)],
                                        input=identity.code_requirement(TEAM) + suffix,
                                        text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertGreater(output.stat().st_size, 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
