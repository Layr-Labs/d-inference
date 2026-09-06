#!/usr/bin/env python3
import argparse
from datetime import datetime, timedelta, timezone
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import shutil
import tarfile
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("signing_validation", ROOT / "scripts/provider-signing-validation.py")
VALIDATION = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VALIDATION)


class SigningValidationTests(unittest.TestCase):
    def test_workflow_has_no_environment_or_publication_route(self):
        workflow = (ROOT / ".github/workflows/provider-signing-validation.yml").read_text()
        self.assertNotRegex(workflow, r"(?m)^\s+environment:")
        self.assertIn("  workflow_dispatch:", workflow)
        self.assertNotRegex(workflow, r"(?m)^  (push|pull_request|workflow_run):")
        self.assertIn("  contents: read", workflow)
        for forbidden in ["contents: write", "secrets.DEV_", "secrets.PROD_", "R2_", "gh release", "aws ", "resolve-provider-release.sh"]:
            self.assertNotIn(forbidden, workflow)
        build_job = workflow.split("  signing:", 1)[0]
        self.assertNotIn("secrets.", build_job)
        self.assertIn("provider-signing-validation.py cli-entitlements", workflow)

    def make_archive(self, directory, mutate=False, info_updates=None):
        source = directory / "source"
        (source / "validation-inputs").mkdir(parents=True)
        app_contents = source / "Darkbloom.app/Contents"
        app_contents.mkdir(parents=True)
        info = {"CFBundleIdentifier": VALIDATION.APP_ID, "CFBundleVersion": "test-version",
                "CFBundleShortVersionString": "test-version", "CFBundleExecutable": "darkbloom"}
        info.update(info_updates or {})
        with (app_contents / "Info.plist").open("wb") as output:
            plistlib.dump(info, output)
        for name in ["entitlements.plist", "entitlements-enclave.plist"]:
            shutil.copy2(ROOT / "provider-swift" / name, source / "validation-inputs" / name)
        (source / "fixture.txt").write_text("synthetic unsigned archive fixture")
        manifest = {"source_sha": "test-source", "version": "test-version", "files": VALIDATION.inventory(source)}
        (source / "unsigned-files.json").write_text(json.dumps(manifest))
        if mutate:
            (source / "fixture.txt").write_text("changed after manifest")
        archive = directory / "unsigned.tar.gz"
        with tarfile.open(archive, "w:gz") as output:
            output.add(source, arcname=".")
        return archive

    def test_unpack_requires_exact_inventory_and_source(self):
        for scenario in ["valid", "mutated", "wrong-source"]:
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                archive = self.make_archive(root, mutate=scenario == "mutated")
                arguments = argparse.Namespace(archive=archive, output=root / "output",
                    source_sha="other-source" if scenario == "wrong-source" else "test-source", version="test-version")
                if scenario == "valid":
                    VALIDATION.unpack(arguments)
                else:
                    with self.assertRaises(ValueError):
                        VALIDATION.unpack(arguments)

    def test_unpack_refuses_path_escape_and_links(self):
        for name, member_type in [("../escape", tarfile.REGTYPE), ("link", tarfile.SYMTYPE), ("hardlink", tarfile.LNKTYPE)]:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                archive = root / "invalid.tar.gz"
                with tarfile.open(archive, "w:gz") as output:
                    member = tarfile.TarInfo(name)
                    member.type = member_type
                    member.linkname = "../escape"
                    output.addfile(member, io.BytesIO())
                with self.assertRaises(ValueError):
                    VALIDATION.unpack(argparse.Namespace(archive=archive, output=root / "output", source_sha="unused", version="unused"))
                self.assertFalse((root / "escape").exists())

    def test_unpack_refuses_mismatched_bundle_identity_and_versions(self):
        for key in ["CFBundleIdentifier", "CFBundleVersion", "CFBundleShortVersionString", "CFBundleExecutable"]:
            with self.subTest(key=key), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                archive = self.make_archive(root, info_updates={key: "wrong-value"})
                with self.assertRaisesRegex(ValueError, "Info.plist"):
                    VALIDATION.unpack(argparse.Namespace(archive=archive, output=root / "output",
                        source_sha="test-source", version="test-version"))

    def test_unpack_bounds_members_total_size_and_count(self):
        cases = [
            ({"MAX_ARCHIVE_BYTES": 0}, [], "Archive size"),
            ({"MAX_MEMBER_BYTES": 4}, [("large", 5)], "member size"),
            ({"MAX_TOTAL_BYTES": 4}, [("first", 3), ("second", 3)], "total size"),
            ({"MAX_ARCHIVE_MEMBERS": 1}, [("first", 0), ("second", 0)], "member count"),
        ]
        for limits, entries, message in cases:
            with self.subTest(message=message), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                archive = root / "bounded.tar.gz"
                with tarfile.open(archive, "w:gz") as output:
                    for name, size in entries:
                        member = tarfile.TarInfo(name)
                        member.size = size
                        output.addfile(member, io.BytesIO(b"x" * size))
                with mock.patch.multiple(VALIDATION, **limits), self.assertRaisesRegex(ValueError, message):
                    VALIDATION.unpack(argparse.Namespace(archive=archive, output=root / "output",
                        source_sha="unused", version="unused"))

    def test_unpack_refuses_duplicate_and_case_aliased_members(self):
        for names in [("member", "member"), ("member", "./member"), ("Member", "member")]:
            with self.subTest(names=names), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                archive = root / "duplicate.tar.gz"
                with tarfile.open(archive, "w:gz") as output:
                    for name in names:
                        output.addfile(tarfile.TarInfo(name), io.BytesIO())
                with self.assertRaisesRegex(ValueError, "Duplicate"):
                    VALIDATION.unpack(argparse.Namespace(archive=archive, output=root / "output",
                        source_sha="unused", version="unused"))

    def test_signed_cli_entitlements_require_group_push_and_no_debug_task(self):
        for scenario in ["valid", "missing-group", "wrong-aps", "debug", "legacy-debug", "malformed-debug"]:
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory() as temporary:
                value = {"keychain-access-groups": [VALIDATION.TEAM + "." + VALIDATION.APP_ID],
                         "com.apple.developer.aps-environment": "production"}
                if scenario == "missing-group": value.pop("keychain-access-groups")
                if scenario == "wrong-aps": value["com.apple.developer.aps-environment"] = "development"
                if scenario == "debug": value["com.apple.security.get-task-allow"] = True
                if scenario == "legacy-debug": value["get-task-allow"] = True
                if scenario == "malformed-debug": value["get-task-allow"] = "false"
                path = Path(temporary) / "entitlements.plist"
                with path.open("wb") as output:
                    plistlib.dump(value, output)
                if scenario == "valid":
                    VALIDATION.cli_entitlements(argparse.Namespace(plist=path))
                else:
                    with self.assertRaises(ValueError):
                        VALIDATION.cli_entitlements(argparse.Namespace(plist=path))

    def test_profile_requires_team_access_group_push_and_expiry(self):
        for scenario in ["valid", "team", "group", "push", "expiry"]:
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory() as temporary:
                value = {"TeamIdentifier": [VALIDATION.TEAM],
                    "ExpirationDate": datetime.now(timezone.utc).replace(tzinfo=None) + timedelta(days=60),
                    "Entitlements": {"keychain-access-groups": [VALIDATION.TEAM + "." + VALIDATION.APP_ID], "aps-environment": "production"}}
                if scenario == "team": value["TeamIdentifier"] = ["OTHER"]
                if scenario == "group": value["Entitlements"]["keychain-access-groups"] = []
                if scenario == "push": value["Entitlements"].pop("aps-environment")
                if scenario == "expiry": value["ExpirationDate"] = datetime.now(timezone.utc).replace(tzinfo=None)
                path = Path(temporary) / "profile.plist"
                with path.open("wb") as output:
                    plistlib.dump(value, output)
                if scenario == "valid":
                    VALIDATION.profile(argparse.Namespace(profile=path))
                else:
                    with self.assertRaises(ValueError):
                        VALIDATION.profile(argparse.Namespace(profile=path))


if __name__ == "__main__":
    unittest.main()
