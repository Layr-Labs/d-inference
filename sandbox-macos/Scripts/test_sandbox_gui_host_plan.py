"""Plan and installed-layout checks use private fixtures, never launchd or VMs."""

import json
import os
from pathlib import Path
import plistlib
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import patch

import sandbox_gui_host_plan as plan
import sandbox_gui_install_validation as installed
from sandbox_gui_user_identity import configured_user
from test_sandbox_gui_user_identity import selected_user


class GUIHostPlanTests(unittest.TestCase):
    def test_one_explicit_aqua_domain_without_credential_switch_or_activation(self):
        config = {"hostID": "60f6a1b2-77db-40d2-bf27-98fce61c8b0d", "storageDirectory": "/private/host/vms",
                  "capacityDirectory": "/private/host/capacity", "tokenFile": "/private/host/host.token"}
        arguments = ["/Library/Sandbox/host", "serve", "--token-file", config["tokenFile"]]
        observations = {"admin_member": True, "runtime_group_member": False, "runtime_gid": None}
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "plan"
            report = plan.generate_gui_plan(config, arguments, configured_user(selected_user()), observations,
                                            {"version": "fixture"}, Path("/source"), Path("/Library/Sandbox"), output)
            value = plistlib.loads((output / "io.darkbloom.sandbox.plist").read_bytes())
            manifest = json.loads((output / "plan.json").read_text())
            self.assertEqual(value["LimitLoadToSessionType"], "Aqua")
            self.assertIs(value["KeepAlive"], False)
            self.assertIs(value["RunAtLoad"], True)
            self.assertEqual(value["ExitTimeOut"], 600)
            self.assertEqual(value["ProgramArguments"], arguments)
            self.assertEqual(value["EnvironmentVariables"], {"LUME_TELEMETRY_ENABLED": "false", "LUME_LOG_LEVEL": "error"})
            self.assertNotIn("UserName", value)
            self.assertNotIn("GroupName", value)
            self.assertEqual(manifest["launchd_domain"], "gui/501")
            self.assertEqual(manifest["host_user"], selected_user())
            identity = output / "host-user.json"
            self.assertEqual(identity.stat().st_mode & 0o777, 0o444)
            self.assertEqual(json.loads(identity.read_text()), {
                "schema_version": 1, "host_id": config["hostID"], "host_user": selected_user()})
            self.assertEqual(manifest["host_identity_file"], str(plan.installed_identity_path(config)))
            self.assertFalse(manifest["automatic_login_startup"])
            self.assertFalse(manifest["production_ready"])
            self.assertFalse(manifest["activation_script_generated"])
            self.assertFalse(report["production_ready"])
            self.assertNotIn("/LaunchAgents/", manifest["installed_job_path"])
            self.assertNotIn("/LaunchDaemons/", manifest["installed_job_path"])
            self.assertFalse(any(path.suffix == ".sh" for path in output.iterdir()))
            self.assertEqual(manifest["qualification_commands"]["bootstrap"],
                             ["/bin/launchctl", "bootstrap", "gui/501", str(plan.installed_job_path(config))])
            self.assertIn("logout cleanup and login recovery", manifest["not_verified"])

    def test_job_path_uses_validated_host_uuid_and_cannot_escape_protected_directory(self):
        with self.assertRaises(ValueError):
            plan.installed_job_path({"hostID": "../../LaunchAgents"})


class GUIInstalledLayoutTests(unittest.TestCase):
    def root_metadata(self, value):
        fields = ("st_dev", "st_ino", "st_size", "st_mtime_ns", "st_ctime_ns", "st_mode", "st_nlink")
        return SimpleNamespace(**{key: getattr(value, key) for key in fields}, st_uid=0)

    def test_job_read_binds_descriptor_contents_and_rejects_different_user_or_extra_options(self):
        expected = plan.launch_agent(["/Library/Sandbox/host", "serve"])
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "job.plist"
            for mutation in ({}, {"UserName": "other"}, {"LimitLoadToSessionType": "Background"},
                             {"KeepAlive": True}, {"KeepAlive": 0}, {"Umask": False},
                             {"ExitTimeOut": 20}, {"ExitTimeOut": True}):
                path.write_bytes(plistlib.dumps(dict(expected, **mutation)))
                path.chmod(0o644)
                metadata = self.root_metadata(path.stat())
                with patch.object(installed, "validate_install_ancestors"), \
                        patch.object(installed, "require_no_extended_acl"), \
                        patch.object(installed.os, "fstat", return_value=metadata):
                    if mutation:
                        with self.assertRaisesRegex(ValueError, "differs"):
                            installed.validate_installed_job(path, expected)
                    else:
                        installed.validate_installed_job(path, expected)

    def test_replaced_job_inode_is_rejected_even_when_contents_match(self):
        expected = plan.launch_agent(["/Library/Sandbox/host", "serve"])
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "job.plist"
            path.write_bytes(plistlib.dumps(expected)); path.chmod(0o644)
            metadata = self.root_metadata(path.stat())
            other = SimpleNamespace(**vars(metadata)); other.st_ino += 1
            with patch.object(installed, "validate_install_ancestors"), \
                    patch.object(installed, "require_no_extended_acl"), \
                    patch.object(installed.os, "fstat", return_value=metadata), \
                    patch.object(Path, "lstat", return_value=other), self.assertRaisesRegex(ValueError, "changed"):
                installed.validate_installed_job(path, expected)

    def test_identity_file_requires_exact_readonly_mode_and_host_binding(self):
        expected = {"schema_version": 1, "host_id": "60f6a1b2-77db-40d2-bf27-98fce61c8b0d", "host_user": selected_user()}
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "host-user.json"
            for mode, replacement in ((0o444, expected), (0o644, expected),
                                      (0o444, dict(expected, host_id="different")),
                                      (0o444, dict(expected, schema_version=True))):
                path.chmod(0o644) if path.exists() else None
                path.write_text(json.dumps(replacement)); path.chmod(mode)
                metadata = self.root_metadata(path.stat())
                with patch.object(installed, "validate_install_ancestors"), \
                        patch.object(installed, "require_no_extended_acl"), \
                        patch.object(installed.os, "fstat", return_value=metadata):
                    if mode == 0o444 and type(replacement["schema_version"]) is int and replacement == expected:
                        installed.validate_installed_identity(path, expected)
                    else:
                        with self.assertRaises(ValueError):
                            installed.validate_installed_identity(path, expected)

    def test_selected_user_private_paths_accept_exact_owner_and_reject_links_or_mode_changes(self):
        with tempfile.TemporaryDirectory(dir=Path.home()) as temporary:
            directory = Path(temporary)
            token = directory / "host.token"
            token.write_text("fixture-token-not-a-secret"); token.chmod(0o600)
            with patch.object(installed, "require_no_extended_acl"):
                installed.validate_private_path(directory, os.geteuid(), 0o700)
                installed.validate_private_path(token, os.geteuid(), 0o600, file=True)
                with self.assertRaisesRegex(ValueError, "ownership"):
                    installed.validate_private_path(token, os.geteuid() + 1, 0o600, file=True)
                token.chmod(0o644)
                with self.assertRaisesRegex(ValueError, "private mode"):
                    installed.validate_private_path(token, os.geteuid(), 0o600, file=True)
                token.chmod(0o600)
                link = directory / "link"
                link.symlink_to(token)
                with self.assertRaises(ValueError):
                    installed.validate_private_path(link, os.geteuid(), 0o600, file=True)
                link.unlink(); os.link(token, link)
                with self.assertRaises(ValueError):
                    installed.validate_private_path(token, os.geteuid(), 0o600, file=True)

    def test_shared_write_parent_rejected_before_private_leaf_can_claim_safety(self):
        with tempfile.TemporaryDirectory(dir=Path.home()) as temporary:
            directory = Path(temporary)
            leaf = directory / "state"; leaf.mkdir(mode=0o700)
            directory.chmod(0o770)
            with patch.object(installed, "require_no_extended_acl"), self.assertRaisesRegex(ValueError, "ancestor"):
                installed.validate_private_path(leaf, os.geteuid(), 0o700)

    def test_encryption_missing_blocks_installed_validation_before_job_success(self):
        config = {"storageDirectory": "/private/host/vms", "capacityDirectory": "/private/host/capacity"}
        with patch.object(installed.os, "geteuid", return_value=0), \
                patch.object(installed, "validate_install_ancestors"), \
                patch.object(installed, "validate_artifact_layout"), \
                patch.object(installed, "validate_private_path", side_effect=lambda path, *_: Path(path)), \
                patch.object(installed, "require_encrypted_backing", side_effect=ValueError("encryption unavailable")), \
                patch.object(installed, "validate_installed_job") as job, self.assertRaisesRegex(ValueError, "encryption"):
            installed.validate_gui_installation(config, [], Path("/Library/Sandbox"), configured_user(selected_user()), {})
        job.assert_not_called()


if __name__ == "__main__":
    unittest.main()
