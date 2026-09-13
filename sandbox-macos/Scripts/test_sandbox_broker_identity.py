"""Broker account checks use captured-shape fixtures; no host account changes."""

from contextlib import ExitStack
import grp
import plistlib
import pwd
import subprocess
import unittest
from unittest.mock import patch

import sandbox_broker_identity as identity


class BrokerIdentityTests(unittest.TestCase):
    def setUp(self):
        self.user = pwd.struct_passwd((identity.BROKER_NAME, "*", 430, 430, "", "/var/empty", "/usr/bin/false"))
        self.private = grp.struct_group((identity.BROKER_NAME, "*", 430, []))
        self.runtime = grp.struct_group((identity.RUNTIME_GROUP_NAME, "*", 431, [identity.BROKER_NAME]))
        self.record = {
            "dsAttrTypeStandard:RecordName": [identity.BROKER_NAME],
            "dsAttrTypeStandard:UniqueID": ["430"],
            "dsAttrTypeStandard:PrimaryGroupID": ["430"],
            "dsAttrTypeStandard:UserShell": ["/usr/bin/false"],
            "dsAttrTypeStandard:NFSHomeDirectory": ["/var/empty"],
            "dsAttrTypeStandard:AuthenticationAuthority": [";DisabledUser;"],
            "dsAttrTypeNative:IsHidden": ["1"],
        }
        self.members = {"admin": False, "wheel": False, identity.RUNTIME_GROUP_NAME: True}
        self.stack = ExitStack()
        self.addCleanup(self.stack.close)
        self.stack.enter_context(patch.object(identity.sys, "platform", "darwin"))
        self.stack.enter_context(patch.object(identity.os, "geteuid", return_value=0))
        self.stack.enter_context(patch.object(identity.pwd, "getpwnam", side_effect=lambda name: self.user))
        self.stack.enter_context(patch.object(identity.pwd, "getpwuid", side_effect=lambda number: self.user))
        self.stack.enter_context(patch.object(identity.grp, "getgrnam", side_effect=lambda name:
                                             self.private if name == identity.BROKER_NAME else self.runtime))
        self.stack.enter_context(patch.object(identity.grp, "getgrgid", side_effect=lambda number:
                                             self.private if number == self.private.gr_gid else self.runtime))
        self.query = self.stack.enter_context(patch.object(identity.subprocess, "run", side_effect=self.response))

    def response(self, arguments, **kwargs):
        self.assertEqual(kwargs["env"]["LC_ALL"], "C")
        self.assertEqual(kwargs["timeout"], 10)
        if arguments[0] == "/usr/bin/dscl":
            self.assertNotIn("Password", arguments)
            self.assertIn("AuthenticationAuthority", arguments)
            output = plistlib.dumps(self.record)
        else:
            self.assertEqual(arguments[:4], ["/usr/bin/dsmemberutil", "checkmembership", "-U", identity.BROKER_NAME])
            member = self.members[arguments[-1]]
            output = b"user is a member of the group\n" if member else b"user is not a member of the group\n"
        return subprocess.CompletedProcess(arguments, 0, output, b"")

    def test_fresh_disabled_role_account_passes(self):
        self.assertEqual(identity.validate_broker_account(), identity.SandboxBrokerAccount(430, 430))
        self.assertEqual(self.query.call_count, 4)

    def test_fully_disabled_shadowhash_shape_passes(self):
        self.record["dsAttrTypeStandard:AuthenticationAuthority"] = [";DisabledUser;;ShadowHash;HASHLIST:<SALTED-SHA512-PBKDF2>"]
        self.assertEqual(identity.validate_broker_account().uid, 430)

    def test_known_empty_home_alias_passes(self):
        self.record["dsAttrTypeStandard:NFSHomeDirectory"] = ["/private/var/empty"]
        self.user = pwd.struct_passwd(
            (identity.BROKER_NAME, "*", 430, 430, "", "/private/var/empty", "/usr/bin/false"))
        self.assertEqual(identity.validate_broker_account().uid, 430)

    def test_nonroot_reader_stops_before_protected_queries(self):
        with patch.object(identity.os, "geteuid", return_value=501), self.assertRaisesRegex(ValueError, "requires root"):
            identity.validate_broker_account()
        self.query.assert_not_called()

    def test_missing_protected_auth_is_unavailable(self):
        self.record.pop("dsAttrTypeStandard:AuthenticationAuthority")
        with self.assertRaisesRegex(ValueError, "verification unavailable"):
            identity.validate_broker_account()

    def test_active_mixed_or_malformed_authorities_are_rejected_without_contents(self):
        for authorities in [[";ShadowHash;secret-fixture"], [";DisabledUser;", ";ShadowHash;secret-fixture"],
                            ["prefix;DisabledUser;secret-fixture"], [";DisabledUser;;unknown;secret-fixture"]]:
            with self.subTest(authorities=authorities):
                self.record["dsAttrTypeStandard:AuthenticationAuthority"] = authorities
                with self.assertRaises(ValueError) as error:
                    identity.validate_broker_account()
                self.assertNotIn("secret-fixture", str(error.exception))

    def test_hidden_setting_is_native_and_required(self):
        self.record.pop("dsAttrTypeNative:IsHidden")
        self.record["dsAttrTypeStandard:IsHidden"] = ["1"]
        with self.assertRaisesRegex(ValueError, "verification unavailable"):
            identity.validate_broker_account()

    def test_visible_account_rejected(self):
        self.record["dsAttrTypeNative:IsHidden"] = ["0"]
        with self.assertRaisesRegex(ValueError, "hidden nonlogin"):
            identity.validate_broker_account()

    def test_login_shell_rejected(self):
        self.record["dsAttrTypeStandard:UserShell"] = ["/bin/zsh"]
        with self.assertRaisesRegex(ValueError, "hidden nonlogin"):
            identity.validate_broker_account()

    def test_nonempty_home_rejected(self):
        self.record["dsAttrTypeStandard:NFSHomeDirectory"] = ["/Users/example"]
        with self.assertRaisesRegex(ValueError, "/var/empty"):
            identity.validate_broker_account()

    def test_directory_and_unix_uid_mismatch_rejected(self):
        self.record["dsAttrTypeStandard:UniqueID"] = ["431"]
        with self.assertRaisesRegex(ValueError, "matching its Unix identity"):
            identity.validate_broker_account()

    def test_admin_and_wheel_memberships_rejected(self):
        for group in ["admin", "wheel"]:
            with self.subTest(group=group):
                self.members = {"admin": False, "wheel": False, identity.RUNTIME_GROUP_NAME: True}
                self.members[group] = True
                with self.assertRaisesRegex(ValueError, "admin or wheel"):
                    identity.validate_broker_account()

    def test_runtime_membership_required(self):
        self.members[identity.RUNTIME_GROUP_NAME] = False
        with self.assertRaisesRegex(ValueError, "member of darkbloom_runtime"):
            identity.validate_broker_account()

    def test_unrecognized_membership_is_unavailable(self):
        original = self.response
        self.query.side_effect = lambda args, **kwargs: original(args, **kwargs) if args[0] == "/usr/bin/dscl" else \
            subprocess.CompletedProcess(args, 0, b"unknown", b"")
        with self.assertRaisesRegex(ValueError, "verification unavailable"):
            identity.validate_broker_account()

    def test_failed_query_does_not_expose_output(self):
        self.query.side_effect = None
        self.query.return_value = subprocess.CompletedProcess([], 1, b"secret-fixture", b"secret-fixture")
        with self.assertRaisesRegex(ValueError, "verification unavailable") as error:
            identity.validate_broker_account()
        self.assertNotIn("secret-fixture", str(error.exception))

    def test_malformed_plist_is_unavailable(self):
        self.query.side_effect = None
        for payload in [b"not plist secret-fixture", b'<?xml version="1.0"?><plist><dict><key>invalid</dict>']:
            self.query.return_value = subprocess.CompletedProcess([], 0, payload, b"")
            with self.subTest(payload=payload), self.assertRaisesRegex(ValueError, "verification unavailable"):
                identity.validate_broker_account()

    def test_root_or_shared_primary_group_rejected(self):
        for uid, gid in [(0, 430), (430, 0), (430, 20)]:
            with self.subTest(uid=uid, gid=gid):
                self.user = pwd.struct_passwd((identity.BROKER_NAME, "*", uid, gid, "", "/var/empty", "/usr/bin/false"))
                with self.assertRaisesRegex(ValueError, "dedicated non-root"):
                    identity.validate_broker_account()

    def test_runtime_and_private_groups_must_differ(self):
        self.runtime = grp.struct_group((identity.RUNTIME_GROUP_NAME, "*", 430, [identity.BROKER_NAME]))
        with self.assertRaisesRegex(ValueError, "dedicated non-root"):
            identity.validate_broker_account()

    def test_runtime_numeric_gid_must_resolve_to_canonical_runtime_group(self):
        with patch.object(identity.grp, "getgrgid", side_effect=lambda number: self.private if number == 430
                          else grp.struct_group(("another_group", "*", 431, []))):
            with self.assertRaisesRegex(ValueError, "dedicated non-root"):
                identity.validate_broker_account()

    def test_private_and_runtime_gids_cannot_alias_admin_even_when_names_match(self):
        self.private = grp.struct_group((identity.BROKER_NAME, "*", 80, []))
        self.user = pwd.struct_passwd((identity.BROKER_NAME, "*", 430, 80, "", "/var/empty", "/usr/bin/false"))
        with self.assertRaisesRegex(ValueError, "dedicated non-root"):
            identity.validate_broker_account()
        self.private = grp.struct_group((identity.BROKER_NAME, "*", 430, []))
        self.user = pwd.struct_passwd((identity.BROKER_NAME, "*", 430, 430, "", "/var/empty", "/usr/bin/false"))
        self.runtime = grp.struct_group((identity.RUNTIME_GROUP_NAME, "*", 80, []))
        with self.assertRaisesRegex(ValueError, "dedicated non-root"):
            identity.validate_broker_account()


if __name__ == "__main__":
    unittest.main(verbosity=2)
