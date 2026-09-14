#!/usr/bin/env python3
"""Release tooling tests exercise refusal paths without installing anything."""

import datetime as dt
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from sandbox_release_support import (
    HOST_ID, PACKAGE, TEAM, file_inventory, new_directory, require_encrypted_backing, validate_profile_data,
)
from sandbox_install_validation import validate_artifact_layout
from sandbox_guest_release import GUEST_FILES, copy_guest_release, validate_guest_release
from test_sandbox_broker_identity import BrokerIdentityTests
from test_sandbox_gui_user_identity import GUIUserIdentityTests, selected_user
from test_sandbox_gui_host_plan import GUIHostPlanTests, GUIInstalledLayoutTests
from sandbox_gui_user_identity import configured_user

spec = importlib.util.spec_from_file_location("prepare_host", PACKAGE / "Scripts/prepare-sandbox-host.py")
prepare_host = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare_host)
package_spec = importlib.util.spec_from_file_location("package_release", PACKAGE / "Scripts/package-sandbox-release.py")
package_release = importlib.util.module_from_spec(package_spec)
package_spec.loader.exec_module(package_release)


def profile():
    return {
        "Name": "Sandbox fixture", "UUID": "fixture", "TeamIdentifier": [TEAM],
        "ExpirationDate": dt.datetime.now() + dt.timedelta(days=1),
        "ProvisionsAllDevices": True,
        "Entitlements": {"com.apple.application-identifier": TEAM + "." + HOST_ID,
                         "keychain-access-groups": [TEAM + ".*"]},
    }


class ProfileTests(unittest.TestCase):
    def test_matching_developer_id_profile(self):
        self.assertEqual(validate_profile_data(profile())["keychain_access_group"], TEAM + "." + HOST_ID)

    def test_provider_profile_is_not_sandbox_profile(self):
        value = profile()
        value["Entitlements"]["com.apple.application-identifier"] = TEAM + ".io.darkbloom.provider"
        with self.assertRaisesRegex(ValueError, "explicitly authorize"):
            validate_profile_data(value)

    def test_wildcard_app_identifier_is_rejected(self):
        value = profile()
        value["Entitlements"]["com.apple.application-identifier"] = TEAM + ".*"
        with self.assertRaises(ValueError):
            validate_profile_data(value)

    def test_expired_profile_is_rejected(self):
        value = profile()
        value["ExpirationDate"] = dt.datetime.now() - dt.timedelta(days=1)
        with self.assertRaisesRegex(ValueError, "expired"):
            validate_profile_data(value)

    def test_debug_profile_is_rejected(self):
        value = profile()
        value["Entitlements"]["get-task-allow"] = True
        with self.assertRaisesRegex(ValueError, "debuggable"):
            validate_profile_data(value)

    def test_wrong_keychain_group_is_rejected(self):
        value = profile()
        value["Entitlements"]["keychain-access-groups"] = [TEAM + ".io.darkbloom.provider"]
        with self.assertRaisesRegex(ValueError, "keychain"):
            validate_profile_data(value)


class ArtifactTests(unittest.TestCase):
    def test_installed_private_root_cannot_be_reported_broker_readable(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with self.assertRaisesRegex(ValueError, "broker-traversable"):
                validate_artifact_layout(root, owner_uid=os.geteuid())

    def test_readable_release_preserves_immutable_lume_modes_and_xattrs(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            root.chmod(0o755)
            binary = root / "guest"
            binary.write_bytes(b"signed-fixture")
            binary.chmod(0o755)
            lume = root / "lume"
            lume.mkdir()
            runtime = lume / "lume"
            runtime.write_bytes(b"pinned-fixture")
            runtime.chmod(0o555)
            lume.chmod(0o555)
            subprocess.run(["/usr/bin/xattr", "-w", "com.darkbloom.test.signature", "retained", str(binary)], check=True)
            try:
                validate_artifact_layout(root, owner_uid=os.geteuid())
                self.assertEqual(runtime.stat().st_mode & 0o777, 0o555)
                self.assertEqual(subprocess.check_output(["/usr/bin/xattr", "-p", "com.darkbloom.test.signature", str(binary)]).strip(), b"retained")
                lume.chmod(0o755)
                with self.assertRaisesRegex(ValueError, "immutable"):
                    validate_artifact_layout(root, owner_uid=os.geteuid())
            finally:
                lume.chmod(0o755)
                runtime.chmod(0o755)

    def test_installed_extended_acl_is_rejected_even_when_modes_are_readable(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            root.chmod(0o755)
            path = root / "tool"
            path.write_text("fixture")
            path.chmod(0o644)
            subprocess.run(["/bin/chmod", "+a", "everyone allow write", str(path)], check=True)
            with self.assertRaisesRegex(ValueError, "extended ACL"):
                validate_artifact_layout(root, owner_uid=os.geteuid())

    def test_backing_volume_requires_boolean_encryption_evidence(self):
        for filevault in [False, None, "true", True]:
            with self.subTest(filevault=filevault), tempfile.TemporaryDirectory() as temporary:
                info = {"FilesystemType": "apfs", "Encryption": True}
                if filevault is not None:
                    info["FileVault"] = filevault
                results = [subprocess.CompletedProcess([], 0, "Filesystem blocks used available capacity mounted\n/dev/disk9s1 1 0 1 0% /Volumes/test\n"),
                           subprocess.CompletedProcess([], 0, plistlib.dumps(info))]
                with patch("sandbox_release_support.run", side_effect=results):
                    if filevault is True:
                        self.assertEqual(require_encrypted_backing(Path(temporary))["scheme"], "filevault")
                    else:
                        with self.assertRaisesRegex(ValueError, "FileVault"):
                            require_encrypted_backing(Path(temporary))

    def test_output_is_exclusive(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "release"
            new_directory(path)
            with self.assertRaisesRegex(ValueError, "already exists"):
                new_directory(path)

    def test_file_tamper_changes_inventory(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary)
            (path / "bootstrap").write_text("approved")
            before = file_inventory(path)
            (path / "bootstrap").write_text("changed")
            self.assertNotEqual(before, file_inventory(path))

    def test_symlink_and_hardlink_rejected(self):
        for kind in ["symlink", "hardlink"]:
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as temporary:
                path = Path(temporary)
                (path / "source").write_text("source")
                if kind == "symlink":
                    (path / "alias").symlink_to(path / "source")
                else:
                    os.link(path / "source", path / "alias")
                with self.assertRaisesRegex(ValueError, "link"):
                    file_inventory(path)

    def test_manifest_does_not_accept_modified_bootstrap(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary)
            (path / "bootstrap").write_text("approved")
            files = file_inventory(path)
            (path / "release-manifest.json").write_text(json.dumps({
                "schema_version": 1, "signing_mode": "developer_id",
                "provisioning": {"profile": "fixture"}, "files": files,
            }))
            (path / "bootstrap").write_text("modified")
            with patch.object(prepare_host, "verify_signature"), self.assertRaisesRegex(ValueError, "signed manifest"):
                prepare_host.validate_package(path)


class HostConfigurationTests(unittest.TestCase):
    def settings(self):
        return {"coordinatorURL": "wss://coordinator.example/ws/sandbox-host",
                "hostID": "60f6a1b2-77db-40d2-bf27-98fce61c8b0d",
                "tokenFile": "/var/db/dbsandbox/host.token", "storageDirectory": "/var/db/dbsandbox/vms",
                "capacityDirectory": "/var/db/dbsandbox/capacity", "baseImageIDs": ["base-v1"],
                "maximumCPUCount": 8, "maximumMemoryGiB": 32,
                "maximumGrowthGiB": 320, "storageHeadroomGiB": 20}

    def test_token_is_path_only_and_development_flags_absent(self):
        args = prepare_host.host_arguments(self.settings(), Path("/Library/Sandbox"))
        self.assertEqual(args[args.index("--token-file") + 1], "/var/db/dbsandbox/host.token")
        self.assertNotIn("--allow-insecure-loopback", args)
        self.assertNotIn("--development-ad-hoc-lume", args)

    def test_old_daemon_plan_refuses_before_any_package_or_output_work(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with patch.object(prepare_host, "validate_package") as package, \
                    patch("sys.argv", ["prepare-sandbox-host.py", "--package", "/fixture/release",
                         "--configuration", str(root / "missing.json"), "--install-root", "/Library/Sandbox",
                         "--output", str(root / "plan")]):
                with self.assertRaisesRegex(ValueError, "LaunchDaemon deployment is unsupported"):
                    prepare_host.main()
                package.assert_not_called()
                self.assertFalse((root / "plan").exists())

    def test_gui_installed_verifier_requires_selected_identity_before_layout_success(self):
        with tempfile.TemporaryDirectory() as temporary:
            settings = Path(temporary) / "host.json"
            settings.write_text(json.dumps(dict(self.settings(), hostUser=selected_user())))
            with patch.object(prepare_host, "validate_gui_user", side_effect=ValueError("selected identity changed")), \
                    patch.object(prepare_host, "validate_gui_installation") as layout, \
                    patch("sys.argv", ["prepare-sandbox-host.py", "--package", "/fixture/release",
                         "--configuration", str(settings), "--install-root", "/Library/Sandbox",
                         "--gui-user-plan", "--verify-installed"]):
                with self.assertRaisesRegex(ValueError, "selected identity changed"):
                    prepare_host.main()
                layout.assert_not_called()

    def test_gui_main_generates_only_bound_qualification_artifacts(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config = root / "host.json"
            settings = dict(self.settings(), hostUser=selected_user())
            config.write_text(json.dumps(settings))
            user = configured_user(selected_user())
            observations = {"admin_member": True, "runtime_group_member": True, "runtime_gid": 431}
            with patch.object(prepare_host, "validate_package", return_value={"version": "fixture"}), \
                    patch.object(prepare_host, "validate_gui_user", return_value=(user, observations)) as identity, \
                    patch("sys.argv", ["prepare-sandbox-host.py", "--gui-user-plan", "--package", "/fixture/release",
                         "--configuration", str(config), "--install-root", "/Library/Sandbox",
                         "--output", str(root / "plan")]):
                prepare_host.main()
            identity.assert_called_once_with(selected_user(), require_runtime_membership=False)
            value = json.loads((root / "plan/plan.json").read_text())
            self.assertFalse(value["production_ready"])
            self.assertFalse(value["activation_script_generated"])
            self.assertEqual(value["host_user"], selected_user())
            self.assertEqual(sorted(path.name for path in (root / "plan").iterdir()),
                             ["INSTALLATION_PLAN.md", "io.darkbloom.sandbox.plist", "plan.json"])

    def test_gui_installed_release_must_match_the_selected_signed_package(self):
        with tempfile.TemporaryDirectory() as temporary:
            config = Path(temporary) / "host.json"
            config.write_text(json.dumps(dict(self.settings(), hostUser=selected_user())))
            with patch.object(prepare_host, "validate_package", side_effect=[{"version": "one"}, {"version": "two"}]), \
                    patch.object(prepare_host, "validate_gui_user", return_value=(configured_user(selected_user()), {})), \
                    patch.object(prepare_host, "validate_gui_installation") as layout, \
                    patch("sys.argv", ["prepare-sandbox-host.py", "--gui-user-plan", "--package", "/fixture/release",
                         "--configuration", str(config), "--install-root", "/Library/Sandbox", "--verify-installed"]):
                with self.assertRaisesRegex(ValueError, "selected signed package"):
                    prepare_host.main()
                layout.assert_not_called()

    def test_coordinator_route_query_fragment_and_malformed_authority_are_rejected(self):
        bad = [
            "wss://coordinator.example/v1/sandbox-hosts/ws",
            "wss://coordinator.example/ws/sandbox-host/",
            "wss://coordinator.example/%77s/sandbox-host",
            "wss://coordinator.example/ws/sandbox-host?token=swordfish",
            "wss://coordinator.example/ws/sandbox-host?",
            "wss://coordinator.example/ws/sandbox-host#fragment",
            "wss://coordinator.example/ws/sandbox-host#",
            "wss://@coordinator.example/ws/sandbox-host",
            "wss://coordinator.example:65536/ws/sandbox-host",
            "wss://coordinator.example:0/ws/sandbox-host",
            "wss://coordinator.example:abc/ws/sandbox-host",
            "wss://coordinator.example:/ws/sandbox-host",
            "wss://bad host/ws/sandbox-host",
            "wss://-host.example/ws/sandbox-host",
            "wss://999.999.999.999/ws/sandbox-host",
            "wss://coordinator.\nexample/ws/sandbox-host",
            "wss://[not-ipv6]/ws/sandbox-host",
            "wss://[::1]extra/ws/sandbox-host",
            "wss://[::1]extra:443/ws/sandbox-host",
            "wss://[fe80::1%en0]/ws/sandbox-host",
        ]
        for url in bad:
            value = self.settings(); value["coordinatorURL"] = url
            with self.subTest(url=url), self.assertRaises(ValueError) as error:
                prepare_host.host_arguments(value, Path("/Library/Sandbox"))
            self.assertNotIn("swordfish", str(error.exception))

    def test_valid_dns_ipv4_and_ipv6_urls_reach_the_generated_host_arguments(self):
        for url in ["wss://coordinator.example/ws/sandbox-host", "wss://127.0.0.1:443/ws/sandbox-host",
                    "wss://[2001:db8::1]:8443/ws/sandbox-host", "wss://[::1]/ws/sandbox-host"]:
            value = self.settings(); value["coordinatorURL"] = url
            args = prepare_host.host_arguments(value, Path("/Library/Sandbox"))
            self.assertEqual(args[args.index("--coordinator") + 1], url)

    def test_embedded_credentials_and_insecure_transport_rejected(self):
        for url in ["ws://example.test", "wss://user:secret@example.test"]:
            value = self.settings()
            value["coordinatorURL"] = url
            with self.assertRaises(ValueError):
                prepare_host.host_arguments(value, Path("/Library/Sandbox"))

    def test_traversal_and_overlapping_paths_rejected(self):
        for token in ["/tmp/../token", "/var/db/dbsandbox/vms", "relative"]:
            value = self.settings()
            value["tokenFile"] = token
            with self.assertRaises(ValueError):
                prepare_host.host_arguments(value, Path("/Library/Sandbox"))

    def test_guest_installer_refuses_non_root(self):
        if os.geteuid() == 0:
            self.skipTest("non-root refusal must run as non-root")
        result = subprocess.run(["/bin/zsh", str(PACKAGE / "Scripts/install-sandbox-guest.sh"), "--install"],
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("requires root inside the guest", result.stderr)


class GuestReuseTests(unittest.TestCase):
    def source(self, root):
        source = root / "source"
        source.mkdir(mode=0o700)
        guest = source / "guest"
        guest.mkdir(mode=0o755)
        for name in GUEST_FILES:
            target = guest / name
            target.write_bytes(("qualified-" + name).encode())
            target.chmod(0o644 if name.endswith(".plist") else 0o755)
        self.manifest(source)
        return source

    def manifest(self, source, signing_mode="developer_id"):
        manifest = source / "release-manifest.json"
        inventory = file_inventory(source)
        inventory.pop("release-manifest.json", None)
        manifest.write_text(json.dumps({"schema_version": 1, "signing_mode": signing_mode, "files": inventory}))
        manifest.chmod(0o600)

    def test_reuse_copies_exact_guest_hashes_and_xattrs_without_resigning(self):
        with tempfile.TemporaryDirectory(dir="/private/tmp") as temporary:
            root = Path(temporary)
            source = self.source(root)
            binary = source / "guest/darkbloom-sandbox-guest"
            subprocess.run(["/usr/bin/xattr", "-w", "com.darkbloom.test.signature", "unchanged", str(binary)], check=True)
            before = file_inventory(source)
            with patch("sandbox_guest_release.verify_signature") as verify:
                metadata = copy_guest_release(source, root / "copied")
            self.assertEqual(metadata["files"], file_inventory(root / "copied"))
            self.assertEqual(before, file_inventory(source))
            self.assertEqual(subprocess.check_output(["/usr/bin/xattr", "-p", "com.darkbloom.test.signature",
                                                      str(root / "copied/darkbloom-sandbox-guest")]).strip(), b"unchanged")
            self.assertTrue(all(call.args[2] is True for call in verify.call_args_list))
            self.assertTrue(any(call.args[1] == "io.darkbloom.sandbox.guest" for call in verify.call_args_list))

    def test_changed_guest_or_unexpected_payload_is_rejected(self):
        for mutation in ["bytes", "extra", "ad_hoc"]:
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory(dir="/private/tmp") as temporary:
                root = Path(temporary)
                source = self.source(root)
                if mutation == "bytes":
                    (source / "guest/install-sandbox-guest.sh").write_text("changed")
                elif mutation == "extra":
                    (source / "guest/unexpected").write_text("extra")
                    self.manifest(source)
                else:
                    self.manifest(source, signing_mode="development_ad_hoc")
                with patch("sandbox_guest_release.verify_signature"), self.assertRaises(ValueError):
                    copy_guest_release(source, root / "destination")
                self.assertFalse((root / "destination").exists())

    def test_writable_acl_and_symlink_metadata_cannot_be_reused(self):
        for mutation in ["writable", "acl", "symlink"]:
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory(dir="/private/tmp") as temporary:
                root = Path(temporary)
                source = self.source(root)
                path = source / "guest/install-sandbox-guest.sh"
                if mutation == "writable":
                    path.chmod(0o777)
                elif mutation == "acl":
                    subprocess.run(["/bin/chmod", "+a", "everyone allow write", str(path)], check=True)
                else:
                    path.unlink()
                    path.symlink_to(source / "guest/darkbloom-sandbox-guest")
                with patch("sandbox_guest_release.verify_signature"), self.assertRaises(ValueError):
                    validate_guest_release(source)

    def test_host_only_packaging_does_not_require_or_resign_guest_binary(self):
        with tempfile.TemporaryDirectory(dir="/private/tmp") as temporary:
            root = Path(temporary)
            source = self.source(root)
            binaries = root / "binaries"
            binaries.mkdir()
            host = binaries / "darkbloom-sandboxd"
            host.write_text("#!/bin/sh\nprintf 'darkbloom-sandboxd 1.0.0\\n'\n")
            host.chmod(0o755)
            with patch("sandbox_guest_release.verify_signature"), patch.object(package_release, "sign") as sign, \
                    patch("sys.argv", ["package-sandbox-release.py", "--output", str(root / "release"),
                                       "--binary-directory", str(binaries), "--guest-release", str(source)]):
                package_release.main()
            self.assertEqual([call.args[1] for call in sign.call_args_list],
                             ["io.darkbloom.sandbox", "io.darkbloom.sandbox.release-manifest"])
            manifest = json.loads((root / "release/release-manifest.json").read_text())
            self.assertEqual(manifest["guest_origin"]["files"], file_inventory(source / "guest"))



if __name__ == "__main__":
    unittest.main(verbosity=2)
