#!/usr/bin/env python3
"""Run the signing keychain scripts against a recording `security` stand-in.

scripts/import-signing-certificate.sh and scripts/remove-signing-keychain.sh
are the one keychain path of every workflow that signs. These tests run the
real scripts with a fake `security` first on PATH, so no keychain, certificate
or runner is involved, and check the calls they make and what they leave
behind.
"""
import base64
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
IMPORT = ROOT / "scripts/import-signing-certificate.sh"
REMOVE = ROOT / "scripts/remove-signing-keychain.sh"
IDENTITY = "Developer ID Application: Example, Inc. (ABCDE12345)"
CERTIFICATE = b"\x30\x82 not a real certificate \x00\xff"
LOGIN = "/Users/runner/Library/Keychains/login.keychain-db"

# Records every call, and has the three effects the scripts depend on: a
# created keychain exists, a deleted one is gone, and the search list and the
# identities can be read.
SECURITY = r"""#!/bin/bash
printf '%s\n' "$*" >> "$STUB_LOG"
case "$1" in
  create-keychain)
    : > "${@: -1}"
    ;;
  delete-keychain)
    if [ "${STUB_DELETE:-ok}" = fail ]; then exit 1; fi
    if [ "${STUB_DELETE:-ok}" = ok ]; then rm -f "${@: -1}"; fi
    ;;
  list-keychains)
    if [ "$#" -eq 3 ]; then printf '    "%s"\n' "$STUB_LOGIN"; fi
    ;;
  import)
    cp "$2" "$STUB_LOG.certificate"
    if [ "${STUB_IMPORT:-ok}" != ok ]; then exit 1; fi
    ;;
  find-identity)
    printf '%s\n' "${STUB_IDENTITIES:-     0 identities found}"
    ;;
esac
exit 0
"""


class KeychainScriptCase(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / "bin").mkdir()
        (self.root / "runner-temp").mkdir()
        stub = self.root / "bin/security"
        stub.write_text(SECURITY)
        stub.chmod(0o755)
        self.log = self.root / "security.log"
        self.keychain = self.root / "runner-temp/signing.keychain-db"
        self.env = {"PATH": f"{self.root / 'bin'}:/usr/bin:/bin:/usr/sbin:/sbin",
                    "RUNNER_TEMP": str(self.root / "runner-temp"), "HOME": str(self.root),
                    "STUB_LOG": str(self.log), "STUB_LOGIN": LOGIN}

    def run_script(self, script, *arguments, **env):
        return subprocess.run(["bash", str(script), *arguments], env={**self.env, **env},
                              capture_output=True, text=True)

    def calls(self):
        return self.log.read_text().splitlines() if self.log.exists() else []

    def call(self, command):
        matches = [line for line in self.calls() if line.split(" ", 1)[0] == command]
        self.assertEqual(len(matches), 1, (command, self.calls()))
        return matches[0]


class ImportTests(KeychainScriptCase):
    SECRETS = {"P12_BASE64": base64.b64encode(CERTIFICATE).decode(), "P12_PASSWORD": "p12-secret"}

    VALID = f'  1) 0123456789ABCDEF0123456789ABCDEF01234567 "{IDENTITY}"\n     1 valid identities found'

    def import_certificate(self, **env):
        return self.run_script(IMPORT, str(self.keychain),
                               **{**self.SECRETS, "STUB_IDENTITIES": self.VALID, **env})

    def test_a_certificate_without_a_valid_identity_is_refused(self):
        result = self.import_certificate(STUB_IDENTITIES="     0 valid identities found")
        self.assertEqual(result.returncode, 1)
        self.assertIn("no valid code-signing identity", result.stderr)

    def test_a_certificate_with_another_identity_is_refused(self):
        self.assertEqual(self.import_certificate(DEVELOPER_ID=IDENTITY).returncode, 0)
        self.log.unlink()
        self.keychain.unlink()
        result = self.import_certificate(DEVELOPER_ID="Developer ID Application: Other, Inc. (ZZZZZ99999)")
        self.assertEqual(result.returncode, 1)
        self.assertIn("not the expected Developer ID identity", result.stderr)

    def password(self):
        match = re.fullmatch(r"create-keychain -p ([0-9a-f]{48}) " + re.escape(str(self.keychain)),
                             self.call("create-keychain"))
        self.assertIsNotNone(match, self.call("create-keychain"))
        return match.group(1)

    def test_the_keychain_password_is_random_and_stays_inside_the_script(self):
        result = self.import_certificate()
        self.assertEqual(result.returncode, 0, result.stderr)
        first = self.password()
        self.assertEqual(self.call("unlock-keychain"), f"unlock-keychain -p {first} {self.keychain}")
        self.assertEqual(self.call("set-key-partition-list"),
                         f"set-key-partition-list -S apple-tool:,apple: -s -k {first} {self.keychain}")
        # Nothing the job log or a later step can read carries it.
        self.assertNotIn(first, result.stdout + result.stderr)
        self.assertNotIn("p12-secret", result.stdout + result.stderr)
        # A second job gets another password.
        self.log.unlink()
        self.keychain.unlink()
        self.assertEqual(self.import_certificate().returncode, 0)
        self.assertNotEqual(self.password(), first)

    def test_the_key_is_imported_non_extractable_for_codesign_only(self):
        self.assertEqual(self.import_certificate().returncode, 0)
        imported = self.call("import")
        certificate = imported.split(" ", 2)[1]
        self.assertEqual(imported, f"import {certificate} -k {self.keychain} -P p12-secret "
                                   "-T /usr/bin/codesign -f pkcs12 -x")
        self.assertEqual(self.call("set-keychain-settings"), f"set-keychain-settings -lut 3600 {self.keychain}")
        self.assertEqual(self.call("find-identity"), f"find-identity -v -p codesigning {self.keychain}")

    def test_the_decoded_certificate_exists_only_under_runner_temp_and_is_removed(self):
        self.assertEqual(self.import_certificate().returncode, 0)
        certificate = Path(self.call("import").split(" ", 2)[1])
        self.assertEqual(certificate.parent, self.root / "runner-temp")
        self.assertEqual(Path(str(self.log) + ".certificate").read_bytes(), CERTIFICATE)
        self.assertFalse(certificate.exists())
        self.assertEqual(sorted(path.name for path in (self.root / "runner-temp").iterdir()),
                         [self.keychain.name])

    def test_a_failed_import_still_removes_the_certificate(self):
        result = self.import_certificate(STUB_IMPORT="fail")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(Path(self.call("import").split(" ", 2)[1]).exists())
        self.assertFalse(any(line.startswith("set-key-partition-list") for line in self.calls()))

    def test_the_new_keychain_leads_the_existing_search_list(self):
        self.assertEqual(self.import_certificate().returncode, 0)
        listing = [line for line in self.calls() if line.startswith("list-keychains")]
        self.assertEqual(listing, ["list-keychains -d user", f"list-keychains -d user -s {self.keychain} {LOGIN}"])

    def test_missing_secrets_or_an_existing_keychain_stop_before_any_keychain_call(self):
        for missing in ("P12_BASE64", "P12_PASSWORD"):
            with self.subTest(missing=missing):
                result = self.import_certificate(**{missing: ""})
                self.assertEqual(result.returncode, 1)
                self.assertIn("not configured", result.stderr)
                self.assertEqual(self.calls(), [])
        self.keychain.write_bytes(b"left by an earlier step")
        result = self.import_certificate()
        self.assertEqual(result.returncode, 1)
        self.assertIn("already exists", result.stderr)
        self.assertEqual(self.calls(), [])
        self.assertEqual(self.run_script(IMPORT, **self.SECRETS).returncode, 2)
        self.assertEqual(self.run_script(IMPORT, "", **self.SECRETS).returncode, 2)
        self.assertEqual(self.calls(), [])


class RemoveTests(KeychainScriptCase):
    def setUp(self):
        super().setUp()
        self.keychain.write_bytes(b"keychain")

    def remove(self, *arguments, **env):
        return self.run_script(REMOVE, *(arguments or (str(self.keychain), IDENTITY)), **env)

    def test_deletes_the_keychain_and_reads_every_identity(self):
        result = self.remove()
        self.assertEqual(result.returncode, 0, result.stderr)
        # No -v: a revoked or expired identity left behind is listed too.
        self.assertEqual(self.calls(), [f"delete-keychain {self.keychain}", "find-identity -p codesigning"])
        self.assertFalse(self.keychain.exists())

    def test_an_identity_that_is_still_listed_fails(self):
        listed = f'  1) 0123456789ABCDEF0123456789ABCDEF01234567 "{IDENTITY}" (CSSMERR_TP_CERT_REVOKED)'
        result = self.remove(STUB_IDENTITIES=listed)
        self.assertEqual(result.returncode, 1)
        self.assertIn("still readable", result.stderr)

    def test_a_keychain_that_cannot_be_deleted_fails_before_the_identity_check(self):
        for mode in ("fail", "keep"):
            with self.subTest(mode=mode):
                self.log.unlink(missing_ok=True)
                self.assertNotEqual(self.remove(STUB_DELETE=mode).returncode, 0)
                self.assertEqual(self.calls(), [f"delete-keychain {self.keychain}"])
                self.assertTrue(self.keychain.exists())

    def test_both_arguments_are_required(self):
        for arguments in ((str(self.keychain),), (str(self.keychain), ""), ("", IDENTITY)):
            with self.subTest(arguments=arguments):
                self.assertEqual(self.remove(*arguments).returncode, 2)
                self.assertEqual(self.calls(), [])


if __name__ == "__main__":
    unittest.main()
