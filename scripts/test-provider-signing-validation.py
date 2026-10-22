#!/usr/bin/env python3
import argparse
from datetime import datetime, timedelta, timezone
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
import unittest.mock as mock

import provider_release_identity as release_identity

ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("signing_validation", ROOT / "scripts/provider-signing-validation.py")
VALIDATION = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VALIDATION)
PRODUCTS = release_identity.PRODUCTS
MARKERS = release_identity.DOCUMENT["releaseVersionMarkers"]
PROD, DEV, STAGING = "0.9.20", "0.9.20" + MARKERS["dev"] + "3", "0.9.20" + MARKERS["staging"] + "3"
PROD_NAMES, DEV_NAMES, STAGING_NAMES = (release_identity.identity(v) for v in (PROD, DEV, STAGING))


MACHO_ARM64 = bytes.fromhex("cffaedfe0c000001") + b"\0" * 24


def write_app_with_cluster_helpers(app, omit=None, metallib=b"metal kernels", paged=b"paged source"):
    """A synthetic app with the cluster helpers the release must ship."""
    contents = app / "Contents"
    (contents / "MacOS").mkdir(parents=True, exist_ok=True)
    (contents / "Helpers").mkdir(parents=True, exist_ok=True)
    (contents / "Resources/mlx-swift-lm_MLXLMCommon.bundle").mkdir(parents=True, exist_ok=True)
    (contents / "MacOS/mlx.metallib").write_bytes(b"metal kernels")
    (contents / "Resources/mlx-swift-lm_MLXLMCommon.bundle/pagedattention.metal").write_bytes(b"paged source")
    files = {"darkbloom-cluster-worker": MACHO_ARM64, "darkbloom-cluster-plan": MACHO_ARM64,
             "mlx.metallib": metallib, "pagedattention.metal": paged}
    for name, data in files.items():
        if name == omit:
            continue
        path = contents / "Helpers" / name
        path.write_bytes(data)
        path.chmod(0o755 if name.startswith("darkbloom-") else 0o644)


def cluster_helper_source(root):
    """The directory scripts/build-cluster-helpers.sh leaves: both helpers with their Metal library and paged source."""
    source = root / "cluster-helpers"
    source.mkdir(parents=True, exist_ok=True)
    for name, data in {"darkbloom-cluster-worker": MACHO_ARM64, "darkbloom-cluster-plan": MACHO_ARM64,
                       "mlx.metallib": b"metallib", "pagedattention.metal": b"paged source"}.items():
        (source / name).write_bytes(data)
    return source


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
        # Build, stage and sign use one set of names: the build job resolves
        # them from the candidate, and the signing job receives them.
        self.assertIn("provider_release_identity.py --source candidate", build_job)
        signing_job = workflow.split("  signing:", 1)[1]
        self.assertNotIn("provider_release_identity.py", signing_job)
        for name in ["app_name", "cli_name", "enclave_name", "release_environment"]:
            self.assertIn("${{ needs.build.outputs.%s }}" % name, signing_job)

    def make_archive(self, directory, mutate=False, info_updates=None, version="test-version",
                     app=PROD_NAMES["appBundleName"], executable=PROD_NAMES["cliName"],
                     name=PROD_NAMES["appDisplayName"], packaging=None):
        source = directory / "source"
        (source / "validation-inputs").mkdir(parents=True)
        app_contents = source / app / "Contents"
        app_contents.mkdir(parents=True)
        write_app_with_cluster_helpers(source / app)
        info = {"CFBundleIdentifier": VALIDATION.APP_ID, "CFBundleVersion": version,
                "CFBundleShortVersionString": version, "CFBundleExecutable": executable,
                "CFBundleName": name}
        info.update(info_updates or {})
        with (app_contents / "Info.plist").open("wb") as output:
            plistlib.dump(info, output)
        for name in VALIDATION.SIGNING_ENTITLEMENTS:
            shutil.copy2(ROOT / "provider-swift" / name, source / "validation-inputs" / name)
        (source / "fixture.txt").write_text("synthetic unsigned archive fixture")
        manifest = {"source_sha": "test-source", "version": version, "files": VALIDATION.inventory(source)}
        if packaging is not None:
            manifest["packaging"] = packaging
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

    def test_cluster_helpers_are_required_where_the_installed_provider_looks(self):
        names = list(VALIDATION.CLUSTER_HELPER_EXECUTABLES + VALIDATION.CLUSTER_HELPER_RESOURCES)
        self.assertEqual(names, ["darkbloom-cluster-worker", "darkbloom-cluster-plan", "mlx.metallib", "pagedattention.metal"])
        for omit in [None] + names:
            with self.subTest(omit=omit), tempfile.TemporaryDirectory() as temporary:
                app = Path(temporary) / "Darkbloom.app"
                write_app_with_cluster_helpers(app, omit=omit)
                if omit is None:
                    VALIDATION.check_cluster_helpers(app)
                else:
                    with self.assertRaisesRegex(ValueError, "Contents/Helpers/" + omit + " is missing"):
                        VALIDATION.check_cluster_helpers(app)

    def test_cluster_helpers_must_match_the_apps_metal_library_and_paged_source(self):
        for scenario in ["metallib", "paged", "not-macho", "not-executable", "symlink"]:
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory() as temporary:
                app = Path(temporary) / "Darkbloom.app"
                write_app_with_cluster_helpers(app, metallib=b"other kernels" if scenario == "metallib" else b"metal kernels",
                                               paged=b"other source" if scenario == "paged" else b"paged source")
                worker = app / "Contents/Helpers/darkbloom-cluster-worker"
                if scenario == "not-macho":
                    worker.write_bytes(b"#!/bin/sh\n")
                if scenario == "not-executable":
                    worker.chmod(0o644)
                if scenario == "symlink":
                    worker.unlink()
                    worker.symlink_to(Path(temporary) / "elsewhere")
                with self.assertRaises(ValueError):
                    VALIDATION.check_cluster_helpers(app)

    def test_unpack_refuses_an_artifact_without_cluster_helpers(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive_root = root / "build"
            archive_root.mkdir()
            original = write_app_with_cluster_helpers

            def without_worker(app, **_):
                original(app, omit="darkbloom-cluster-worker")
            with mock.patch(__name__ + ".write_app_with_cluster_helpers", without_worker):
                archive = self.make_archive(archive_root)
            with self.assertRaisesRegex(ValueError, "darkbloom-cluster-worker is missing"):
                VALIDATION.unpack(argparse.Namespace(archive=archive, output=root / "output",
                    source_sha="test-source", version="test-version"))

    def test_stage_copies_built_helpers_and_refuses_an_incomplete_build(self):
        for omit in [None, "darkbloom-cluster-plan", "pagedattention.metal"]:
            with self.subTest(omit=omit), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                built = root / "cluster-helpers"
                built.mkdir()
                for name, data in {"darkbloom-cluster-worker": MACHO_ARM64, "darkbloom-cluster-plan": MACHO_ARM64,
                                   "mlx.metallib": b"metal kernels", "pagedattention.metal": b"paged source"}.items():
                    if name != omit:
                        (built / name).write_bytes(data)
                helpers = root / "Darkbloom.app/Contents/Helpers"
                helpers.mkdir(parents=True)
                if omit is None:
                    VALIDATION.stage_cluster_helpers(built, helpers)
                    self.assertEqual((helpers / "darkbloom-cluster-worker").stat().st_mode & 0o777, 0o755)
                    self.assertEqual((helpers / "mlx.metallib").read_bytes(), b"metal kernels")
                else:
                    with self.assertRaisesRegex(ValueError, "missing from the build: " + omit):
                        VALIDATION.stage_cluster_helpers(built, helpers)
        with self.assertRaisesRegex(ValueError, "build-cluster-helpers.sh"):
            VALIDATION.stage_cluster_helpers(None, Path("/nonexistent"))

    def test_release_workflows_build_ship_and_sign_the_cluster_helpers(self):
        # The release body lives in the reusable workflow release-swift.yml calls per environment.
        release = (ROOT / ".github/workflows/release-provider.yml").read_text()
        validation = (ROOT / ".github/workflows/provider-signing-validation.yml").read_text()
        action = (ROOT / ".github/actions/provider-release-build/action.yml").read_text()
        self.assertIn("scripts/build-cluster-helpers.sh", action)
        self.assertIn("cluster-helpers-dir", action)
        self.assertIn("--cluster-helpers", release)
        self.assertIn("build-cluster-helpers.sh", validation)
        self.assertIn("--cluster-helpers", validation)
        for workflow in [release, validation]:
            self.assertIn("sign-cluster-helpers.sh", workflow)
            self.assertIn("provider-signing-validation.py cluster-helpers", workflow)
        # Never optional again: no silent skip when the artifact lacks them.
        self.assertNotIn('[ -f "$APP/Contents/Helpers/$helper" ] || continue', release)
        self.assertNotIn("mlx-cluster-worker.metallib", release)
        # Every workflow that stages an unsigned app hands it the cluster helpers (stage requires them).
        for path in sorted((ROOT / ".github/workflows").glob("*.yml")):
            text = path.read_text()
            for call in text.split("provider-signing-validation.py stage")[1:]:
                self.assertIn("--cluster-helpers", call.split("--version", 1)[0], path.name)
        signer = (ROOT / "scripts/sign-cluster-helpers.sh").read_text()
        self.assertIn('--identifier "io.darkbloom.$name"', signer)
        self.assertIn("entitlements", signer)

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
        for key in ["CFBundleIdentifier", "CFBundleVersion", "CFBundleShortVersionString", "CFBundleExecutable",
                    "CFBundleName"]:
            with self.subTest(key=key), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                archive = self.make_archive(root, info_updates={key: "wrong-value"})
                with self.assertRaisesRegex(ValueError, "Info.plist"):
                    VALIDATION.unpack(argparse.Namespace(archive=archive, output=root / "output",
                        source_sha="test-source", version="test-version"))

    def test_dev_version_requires_the_dev_app_identity(self):
        layouts = {version: {"app": names["appBundleName"], "executable": names["cliName"],
                             "name": names["appDisplayName"]}
                   for version, names in [(PROD, PROD_NAMES), (DEV, DEV_NAMES), (STAGING, STAGING_NAMES)]}
        for scenario, layout, version, valid in [
                ("dev", layouts[DEV], DEV, True), ("prod", layouts[PROD], PROD, True),
                ("staging", layouts[STAGING], STAGING, True),
                ("prod-layout-dev-version", layouts[PROD], DEV, False),
                ("dev-layout-prod-version", layouts[DEV], PROD, False),
                ("staging-layout-dev-version", layouts[STAGING], DEV, False),
                ("prod-layout-staging-version", layouts[PROD], STAGING, False)]:
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                archive = self.make_archive(root, version=version, **layout)
                arguments = argparse.Namespace(archive=archive, output=root / "output",
                    source_sha="test-source", version=version)
                if valid:
                    VALIDATION.unpack(arguments)
                else:
                    with self.assertRaises(ValueError):
                        VALIDATION.unpack(arguments)

    def test_stage_renames_products_for_a_dev_release(self):
        for version, names in [(PROD, PROD_NAMES), (DEV, DEV_NAMES)]:
            with self.subTest(version=version), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                products = root / "bin"
                products.mkdir()
                for product in [*PRODUCTS.values(), "darkbloom-fan-helper"]:
                    (products / product).write_text(product)
                (root / "mlx.metallib").write_text("metallib")
                # Resource staging is not run here, so the paged-source match is the cluster tests' to check.
                with mock.patch.object(VALIDATION.subprocess, "run"), \
                        mock.patch.object(VALIDATION.subprocess, "check_output", return_value=""), \
                        mock.patch.object(VALIDATION, "check_cluster_helpers"):
                    VALIDATION.stage(argparse.Namespace(source=ROOT, bin=products,
                        metallib=root / "mlx.metallib", output=root / "stage", version=version,
                        cluster_helpers=cluster_helper_source(root)))
                app = root / "stage" / names["appBundleName"] / "Contents"
                self.assertEqual({path.name: path.read_text() for path in (app / "MacOS").iterdir()}, {
                    names["cliName"]: PRODUCTS["cli"], names["enclaveName"]: PRODUCTS["enclave"],
                    "mlx.metallib": "metallib"})
                info = plistlib.loads((app / "Info.plist").read_bytes())
                self.assertEqual(info["CFBundleIdentifier"], VALIDATION.APP_ID)
                self.assertEqual(info["CFBundleExecutable"], names["cliName"])
                self.assertEqual(info["CFBundleName"], names["appDisplayName"])

    def test_receipt_keeps_the_flat_product_names_for_a_dev_app(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = root / DEV_NAMES["appBundleName"] / "Contents"
            (app / "MacOS").mkdir(parents=True)
            for name in [DEV_NAMES["cliName"], DEV_NAMES["enclaveName"], "mlx.metallib"]:
                (app / "MacOS" / name).write_text(name)
            (app / "Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": VALIDATION.APP_ID, "CFBundleVersion": DEV,
                "CFBundleShortVersionString": DEV, "CFBundleExecutable": DEV_NAMES["cliName"],
                "CFBundleName": DEV_NAMES["appDisplayName"]}))
            (root / "unsigned-files.json").write_text(json.dumps(
                {"source_sha": "s", "version": DEV, "submodules": []}))
            notary = root / "notary.json"
            notary.write_text(json.dumps({"status": "Accepted", "id": "n"}))
            with mock.patch.object(VALIDATION, "check_cluster_helpers"):
                VALIDATION.receipt(argparse.Namespace(output=root, notary=notary))
            self.assertEqual({path.name: path.read_text() for path in (root / "bin").iterdir()}, {
                PRODUCTS["cli"]: DEV_NAMES["cliName"], PRODUCTS["enclave"]: DEV_NAMES["enclaveName"],
                "mlx.metallib": "mlx.metallib"})

    def candidate(self, root, document=None):
        """A source checkout; without a document it predates the identity file."""
        for name in VALIDATION.SIGNING_ENTITLEMENTS:
            (root / "provider-swift").mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / "provider-swift" / name, root / "provider-swift" / name)
        if document is not None:
            path = root / release_identity.RELATIVE_IDENTITY_FILE
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps(document))
        return root

    def renamed_document(self):
        document = json.loads(json.dumps(release_identity.DOCUMENT))
        document["environments"]["dev"].update(
            cliName="candidate-cli", enclaveName="candidate-enclave",
            appBundleName="Candidate.app", appDisplayName="Candidate")
        return document

    def test_identity_falls_back_to_tooling_for_a_source_without_the_file(self):
        with tempfile.TemporaryDirectory() as temporary:
            old = self.candidate(Path(temporary) / "old")
            self.assertIs(release_identity.for_source(old), release_identity.DOCUMENT)
            new = self.candidate(Path(temporary) / "new", self.renamed_document())
            self.assertEqual(release_identity.identity(DEV, release_identity.for_source(new))["cliName"],
                             "candidate-cli")
            script = ROOT / "scripts/provider_release_identity.py"
            for source, expected in [(old, PROD_NAMES["appBundleName"]), (new, PROD_NAMES["appBundleName"])]:
                output = subprocess.run([sys.executable, str(script), "--source", str(source), PROD],
                                        capture_output=True, text=True, check=True).stdout
                self.assertIn(f"APP_NAME={expected}\n", output)
            output = subprocess.run([sys.executable, str(script), "--source", str(new), DEV],
                                    capture_output=True, text=True, check=True).stdout
            self.assertIn("APP_NAME=Candidate.app\n", output)
            self.assertEqual(subprocess.run(
                [sys.executable, str(script), "--environment", "--source", str(old), DEV],
                capture_output=True, text=True, check=True).stdout, "dev\n")

    def test_stage_records_the_candidates_names_and_unpack_uses_them(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = self.candidate(root / "candidate", self.renamed_document())
            products = root / "bin"
            products.mkdir()
            for product in [*PRODUCTS.values(), "darkbloom-fan-helper"]:
                (products / product).write_text(product)
            (root / "mlx.metallib").write_text("metallib")
            with mock.patch.object(VALIDATION.subprocess, "run"), \
                    mock.patch.object(VALIDATION.subprocess, "check_output", return_value=""), \
                    mock.patch.object(VALIDATION, "check_cluster_helpers"):
                VALIDATION.stage(argparse.Namespace(source=source, bin=products,
                    metallib=root / "mlx.metallib", output=root / "stage", version=DEV,
                    cluster_helpers=cluster_helper_source(root)))
            manifest = json.loads((root / "stage/unsigned-files.json").read_text())
            self.assertEqual(manifest["packaging"]["appBundleName"], "Candidate.app")
            self.assertEqual(manifest["packaging"]["products"], PRODUCTS)
            self.assertTrue((root / "stage/Candidate.app/Contents/MacOS/candidate-cli").is_file())

    def test_unpack_checks_the_recorded_names(self):
        packaged = {"cliName": "candidate-cli", "enclaveName": "candidate-enclave",
                    "appBundleName": "Candidate.app", "appDisplayName": "Candidate", "products": PRODUCTS}
        for scenario, layout, packaging, valid in [
                ("recorded", {"app": "Candidate.app", "executable": "candidate-cli", "name": "Candidate"},
                 packaged, True),
                ("layout-differs", {"app": "Candidate.app", "executable": "other-cli", "name": "Candidate"},
                 packaged, False),
                ("unsafe-name", {"app": "Candidate.app", "executable": "candidate-cli", "name": "Candidate"},
                 dict(packaged, appBundleName="../Candidate.app"), False)]:
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                archive = self.make_archive(root, version=DEV, packaging=packaging, **layout)
                arguments = argparse.Namespace(archive=archive, output=root / "output",
                    source_sha="test-source", version=DEV)
                if valid:
                    VALIDATION.unpack(arguments)
                else:
                    with self.assertRaises(ValueError):
                        VALIDATION.unpack(arguments)

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

    def test_profile_app_identifier_must_authorize_the_exact_team_and_app(self):
        expected = VALIDATION.TEAM + "." + VALIDATION.APP_ID
        cases = [
            ({}, True),  # Developer ID may omit this entitlement.
            ({"com.apple.application-identifier": expected}, True),
            ({"application-identifier": expected}, True),
            ({"com.apple.application-identifier": VALIDATION.TEAM + ".*"}, True),
            ({"com.apple.application-identifier": VALIDATION.TEAM + ".io.darkbloom.*"}, True),
            ({"com.apple.application-identifier": VALIDATION.TEAM + ".io.darkbloom.other"}, False),
            ({"application-identifier": "OTHERTEAM." + VALIDATION.APP_ID}, False),
            ({"application-identifier": VALIDATION.TEAM + ".unrelated.*"}, False),
            ({"application-identifier": "*"}, False),
            ({"application-identifier": ""}, False),
            ({"application-identifier": [expected]}, False),
            ({"com.apple.application-identifier": expected,
              "application-identifier": VALIDATION.TEAM + ".other"}, False),
        ]
        for app_ids, valid in cases:
            with self.subTest(app_ids=app_ids), tempfile.TemporaryDirectory() as temporary:
                value = {"TeamIdentifier": [VALIDATION.TEAM],
                    "ExpirationDate": datetime.now(timezone.utc).replace(tzinfo=None) + timedelta(days=60),
                    "Entitlements": {"keychain-access-groups": [expected],
                        "com.apple.developer.aps-environment": "production", **app_ids}}
                path = Path(temporary) / "profile.plist"
                path.write_bytes(plistlib.dumps(value))
                if valid:
                    VALIDATION.profile(argparse.Namespace(profile=path))
                else:
                    with self.assertRaisesRegex(ValueError, "application identifier mismatch"):
                        VALIDATION.profile(argparse.Namespace(profile=path))


if __name__ == "__main__":
    unittest.main()
