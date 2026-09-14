"""GUI-user identity fixtures query no live accounts and perform no mutations."""

from contextlib import ExitStack
import grp
import plistlib
import pwd
import stat
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import sandbox_gui_user_identity as identity


def selected_user():
    return {"recordName": "operator", "uid": 501, "primaryGID": 20,
            "generatedUID": "9819F283-43E0-49E9-8BB3-FD44CD75B963", "homeDirectory": "/Users/operator"}


class GUIUserIdentityTests(unittest.TestCase):
    def setUp(self):
        self.expected = selected_user()
        self.user = pwd.struct_passwd(("operator", "*", 501, 20, "", "/Users/operator", "/bin/zsh"))
        self.runtime = grp.struct_group((identity.RUNTIME_GROUP, "*", 431, ["operator"]))
        self.member = {"admin": True, identity.RUNTIME_GROUP: True}
        self.home = SimpleNamespace(st_mode=stat.S_IFDIR | 0o755, st_uid=501)
        self.record = {"dsAttrTypeStandard:" + key: [value] for key, value in {
            "RecordName": "operator", "UniqueID": "501", "PrimaryGroupID": "20",
            "GeneratedUID": self.expected["generatedUID"], "NFSHomeDirectory": "/Users/operator",
            "UserShell": "/bin/zsh"}.items()}
        self.stack = ExitStack()
        self.addCleanup(self.stack.close)
        self.stack.enter_context(patch.object(identity.sys, "platform", "darwin"))
        self.stack.enter_context(patch.object(identity.pwd, "getpwnam", side_effect=lambda _: self.user))
        self.stack.enter_context(patch.object(identity.pwd, "getpwuid", side_effect=lambda _: self.user))
        self.stack.enter_context(patch.object(identity.grp, "getgrgid", side_effect=lambda gid:
                                             grp.struct_group(("staff", "*", 20, [])) if gid == 20 else self.runtime))
        self.stack.enter_context(patch.object(identity.grp, "getgrnam", side_effect=lambda _: self.runtime))
        self.stack.enter_context(patch.object(identity.Path, "lstat", side_effect=lambda: self.home))
        self.commands = []
        self.stack.enter_context(patch.object(identity, "_read", side_effect=self.read))

    def read(self, arguments):
        self.commands.append(arguments)
        if arguments[0] == "/usr/bin/dscl":
            return plistlib.dumps(self.record)
        self.assertEqual(arguments[:4], ["/usr/bin/dsmemberutil", "checkmembership", "-U", "operator"])
        return b"user is a member of the group" if self.member[arguments[-1]] else b"user is not a member of the group"

    def test_selected_admin_and_nonadmin_are_both_explicit_trusted_host_users(self):
        for admin in (True, False):
            self.member["admin"] = admin
            user, result = identity.validate_gui_user(self.expected, require_runtime_membership=True)
            self.assertEqual(user.record(), self.expected)
            self.assertEqual(result, {"admin_member": admin, "runtime_group_member": True, "runtime_gid": 431})
        self.assertTrue(all("AuthenticationAuthority" not in command for command in self.commands))
        self.assertTrue(all(not any(flag in command for flag in ("-create", "-delete", "-passwd")) for command in self.commands))

    def test_generated_uuid_binds_reused_numeric_identity(self):
        self.record["dsAttrTypeStandard:GeneratedUID"] = ["51A1ED26-01C5-4004-82A7-2BFA53F1D20F"]
        with self.assertRaisesRegex(ValueError, "identity changed"):
            identity.validate_gui_user(self.expected)

    def test_local_record_alias_or_missing_attribute_rejected(self):
        for key in self.record:
            with self.subTest(attribute=key):
                previous = self.record[key]
                self.record[key] = previous + ["ambiguous"]
                with self.assertRaises(ValueError):
                    identity.validate_gui_user(self.expected)
                self.record[key] = previous

    def test_unix_reverse_lookup_must_match_selected_local_record(self):
        other = pwd.struct_passwd(("different", "*", 501, 20, "", "/Users/operator", "/bin/zsh"))
        with patch.object(identity.pwd, "getpwuid", return_value=other), self.assertRaisesRegex(ValueError, "Unix identity"):
            identity.validate_gui_user(self.expected)

    def test_missing_runtime_membership_is_plan_observation_but_blocks_installed_validation(self):
        self.member[identity.RUNTIME_GROUP] = False
        self.assertFalse(identity.validate_gui_user(self.expected)[1]["runtime_group_member"])
        with self.assertRaisesRegex(ValueError, "must belong"):
            identity.validate_gui_user(self.expected, require_runtime_membership=True)
        with patch.object(identity.grp, "getgrnam", side_effect=KeyError):
            self.assertIsNone(identity.validate_gui_user(self.expected)[1]["runtime_gid"])

    def test_missing_home_wrong_owner_symlink_and_shared_write_rejected(self):
        for mode, owner in ((stat.S_IFDIR | 0o755, 502), (stat.S_IFLNK | 0o755, 501), (stat.S_IFDIR | 0o775, 501)):
            self.home = SimpleNamespace(st_mode=mode, st_uid=owner)
            with self.subTest(mode=mode, owner=owner), self.assertRaisesRegex(ValueError, "home must"):
                identity.validate_gui_user(self.expected)

    def test_nonlogin_shell_rejected(self):
        self.user = pwd.struct_passwd(("operator", "*", 501, 20, "", "/Users/operator", "/usr/bin/false"))
        with self.assertRaisesRegex(ValueError, "login home"):
            identity.validate_gui_user(self.expected)

    def test_runtime_group_cannot_alias_admin_or_another_named_group(self):
        self.runtime = grp.struct_group((identity.RUNTIME_GROUP, "*", 80, ["operator"]))
        with self.assertRaisesRegex(ValueError, "nonprivileged identity"):
            identity.validate_gui_user(self.expected)
        self.runtime = grp.struct_group((identity.RUNTIME_GROUP, "*", 431, ["operator"]))
        with patch.object(identity.grp, "getgrgid", side_effect=lambda gid:
                          grp.struct_group(("staff", "*", 20, [])) if gid == 20
                          else grp.struct_group(("another", "*", 431, []))), self.assertRaisesRegex(ValueError, "unambiguous"):
            identity.validate_gui_user(self.expected)

    def test_root_system_boolean_ids_malformed_paths_and_identity_assertions_rejected(self):
        for key, value in (("uid", 0), ("uid", 430), ("uid", 2001), ("uid", True), ("primaryGID", 0),
                           ("generatedUID", "9819f283-43e0-49e9-8bb3-fd44cd75b963"),
                           ("generatedUID", "00000000-0000-0000-0000-000000000000"),
                           ("recordName", "../operator"), ("homeDirectory", "/Users/../var/empty"),
                           ("homeDirectory", "/var/empty")):
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                identity.configured_user(dict(self.expected, **{key: value}))
        with self.assertRaises(ValueError):
            identity.configured_user(dict(self.expected, password="never accepted"))

    def test_unrecognized_membership_is_unavailable_not_nonmember(self):
        with patch.object(identity, "_read", return_value=b"unrecognized"), self.assertRaises(ValueError):
            identity._membership(identity.configured_user(self.expected), "admin")


if __name__ == "__main__":
    unittest.main()
