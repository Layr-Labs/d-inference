#!/usr/bin/env python3
import argparse
from datetime import datetime, timedelta, timezone
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import re
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
    def test_workflow_has_no_publication_route_and_signs_in_the_prod_environment(self):
        workflow = (ROOT / ".github/workflows/provider-signing-validation.yml").read_text()
        # Only the job that reads the signing secrets names an environment: prod's
        # branch policy and reviewers apply before it starts. The build job reads
        # no secret and names none.
        self.assertEqual(re.findall(r"(?m)^\s+environment:.*$", workflow), ["    environment: prod"])
        self.assertIn("    environment: prod\n", workflow.split("  signing:", 1)[1].split("    steps:", 1)[0])
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

    def test_workflow_signs_only_reviewed_master_source_with_an_isolated_key(self):
        workflow = (ROOT / ".github/workflows/provider-signing-validation.yml").read_text()
        build_job, signing_job = workflow.split("  signing:", 1)

        def step(job, name):
            return job.split("      - name: " + name + "\n", 1)[1].split("\n      - ", 1)[0]

        # The source gate runs before the candidate is checked out: dispatched
        # on master, the commit verified and on master's ancestry
        # (provider_release_resume.api.verify_validation_source).
        gate = step(build_job, "Require a reviewed master source")
        self.assertIn('run: python3 tooling/scripts/provider-release-resume.py verify-validation-source '
                      '--source "$SOURCE_SHA"', gate)
        self.assertIn("SOURCE_SHA: ${{ inputs.source_sha }}", gate)
        self.assertLess(build_job.index("- name: Require a reviewed master source"),
                        build_job.index("- name: Checkout candidate"))
        self.assertNotIn("commit.verification.verified", workflow)
        # The signing job takes the build job's artifact by id and digest.
        self.assertIn("        id: unsigned_retention\n", step(build_job, "Retain unsigned input for the separate signing job"))
        for output in ("id", "digest"):
            self.assertIn("      unsigned_artifact_%s: ${{ steps.unsigned_retention.outputs.artifact-%s }}\n"
                          % (output, output), build_job)
        fetch = step(signing_job, "Read this run's unsigned artifact")
        self.assertIn('python3 tooling/scripts/provider-release-publication.py download \\\n'
                      '            --artifact-id "$UNSIGNED_ARTIFACT_ID" --artifact-digest "$UNSIGNED_ARTIFACT_DIGEST" \\\n'
                      '            --run-id "$GITHUB_RUN_ID" --directory "$RUNNER_TEMP/incoming"\n', fetch)
        for by_name in ("gh run download", "--name provider-signing-input"):
            self.assertNotIn(by_name, workflow)
        # The key exists for the codesign step alone, through the shared
        # scripts, and is gone before the notarization credentials appear.
        names = ("Embed and check the provisioning profile", "Import Developer ID certificate",
                 "Sign and statically verify the app", "Remove the signing keychain",
                 "Validate Apple notarization", "Staple and verify the notarized app")
        positions = [signing_job.index("      - name: " + name + "\n") for name in names]
        self.assertEqual(positions, sorted(positions))
        keychain = '"$RUNNER_TEMP/signing-validation.keychain-db"'
        self.assertIn("run: bash tooling/scripts/import-signing-certificate.sh " + keychain,
                      step(signing_job, "Import Developer ID certificate"))
        self.assertIn("run: bash tooling/scripts/remove-signing-keychain.sh " + keychain + ' "$DEVELOPER_ID"',
                      step(signing_job, "Remove the signing keychain"))
        owners = {"APPLE_CERTIFICATE_P12": "Import Developer ID certificate",
                  "APPLE_CERTIFICATE_PASSWORD": "Import Developer ID certificate",
                  "PROVISIONING_PROFILE_BASE64": "Embed and check the provisioning profile",
                  "APPLE_ID": "Validate Apple notarization", "APPLE_APP_PASSWORD": "Validate Apple notarization"}
        for secret, owner in owners.items():
            with self.subTest(secret=secret):
                self.assertEqual(workflow.count("secrets." + secret), 1)
                self.assertIn("secrets." + secret, step(signing_job, owner))
        self.assertEqual(workflow.count("secrets."), len(owners))
        notarize = step(signing_job, "Validate Apple notarization")
        self.assertIn("xcrun notarytool submit", notarize)
        for later in ("stapler", "spctl", "codesign", "tooling/scripts"):
            self.assertNotIn(later, notarize)
        self.assertNotIn("--keychain", workflow.split("- name: Remove the signing keychain", 1)[1])

    def make_archive(self, directory, mutate=False, info_updates=None, version="test-version",
                     app=PROD_NAMES["appBundleName"], executable=PROD_NAMES["cliName"],
                     name=PROD_NAMES["appDisplayName"], packaging=None,
                     enclave=PROD_NAMES["enclaveName"], modes=None):
        source = directory / "source"
        (source / "validation-inputs").mkdir(parents=True)
        app_contents = source / app / "Contents"
        app_contents.mkdir(parents=True)
        write_app_with_cluster_helpers(source / app)
        for path in [app_contents / "MacOS" / executable, app_contents / "MacOS" / enclave,
                     app_contents / "Helpers" / VALIDATION.FAN_HELPER]:
            path.write_bytes(MACHO_ARM64)
            path.chmod(0o755)
        for relative, mode in (modes or {}).items():
            (app_contents / relative).chmod(mode)
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

    def staged_from_private_build(self, root):
        """Stages SwiftPM products and cluster helpers that a build under
        umask 077 left at mode 0700, as a private release build does."""
        products = root / "bin"
        products.mkdir()
        for product in [*PRODUCTS.values(), VALIDATION.FAN_HELPER]:
            (products / product).write_bytes(MACHO_ARM64 + product.encode())
            (products / product).chmod(0o700)
        (root / "mlx.metallib").write_bytes(b"metallib")
        helpers = cluster_helper_source(root)
        for name in VALIDATION.CLUSTER_HELPER_EXECUTABLES:
            (helpers / name).chmod(0o700)
        # Resource staging needs ditto; the paged-source match is the cluster tests' to check.
        with mock.patch.object(VALIDATION.subprocess, "run"), \
                mock.patch.object(VALIDATION.subprocess, "check_output", return_value=""), \
                mock.patch.object(VALIDATION, "check_cluster_helpers"):
            VALIDATION.stage(argparse.Namespace(source=ROOT, bin=products, metallib=root / "mlx.metallib",
                output=root / "stage", version=PROD, cluster_helpers=helpers))
        return products

    def executable_paths(self, app, names=PROD_NAMES):
        return [app / "Contents/MacOS" / names["cliName"], app / "Contents/MacOS" / names["enclaveName"],
                *[app / "Contents/Helpers" / name for name in (VALIDATION.FAN_HELPER, *VALIDATION.CLUSTER_HELPER_EXECUTABLES)]]

    def test_stage_pack_and_unpack_keep_every_executable_0755_under_umask_077(self):
        previous = os.umask(0o077)
        try:
            with tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                products = self.staged_from_private_build(root)
                app = root / "stage" / PROD_NAMES["appBundleName"]
                staged = self.executable_paths(app)
                self.assertEqual([path.stat().st_mode & 0o7777 for path in staged], [0o755] * 5)
                # Only the executables change mode; the build outputs keep theirs and every byte.
                self.assertEqual((app / "Contents/MacOS/mlx.metallib").stat().st_mode & 0o777,
                                 (root / "mlx.metallib").stat().st_mode & 0o777)
                for product, name in [(PRODUCTS["cli"], PROD_NAMES["cliName"]), (VALIDATION.FAN_HELPER, None)]:
                    self.assertEqual((products / product).stat().st_mode & 0o777, 0o700)
                    packaged = app / ("Contents/MacOS/" + name if name else "Contents/Helpers/" + product)
                    self.assertEqual(packaged.read_bytes(), (products / product).read_bytes())
                archive = root / "unsigned-provider.tar.gz"
                with tarfile.open(archive, "w:gz") as output:
                    output.add(root / "stage", arcname=".")
                with tarfile.open(archive) as packed:
                    members = {member.name: member.mode for member in packed}
                for path in staged:
                    self.assertEqual(members["./" + str(path.relative_to(root / "stage"))], 0o755)
                with mock.patch.object(VALIDATION, "check_cluster_helpers"):
                    VALIDATION.unpack(argparse.Namespace(archive=archive, output=root / "readback",
                        source_sha="", version=PROD))
                readback = self.executable_paths(root / "readback" / PROD_NAMES["appBundleName"])
                self.assertEqual([path.stat().st_mode & 0o7777 for path in readback], [0o755] * 5)
        finally:
            os.umask(previous)

    def test_unpack_refuses_an_executable_whose_mode_is_not_0755(self):
        executables = [f"MacOS/{PROD_NAMES['cliName']}", f"MacOS/{PROD_NAMES['enclaveName']}",
                       f"Helpers/{VALIDATION.FAN_HELPER}",
                       *[f"Helpers/{name}" for name in VALIDATION.CLUSTER_HELPER_EXECUTABLES]]
        for relative in executables:
            # Modes every supported Python's tar extraction keeps as archived.
            for mode in [0o700, 0o744, 0o644]:
                with self.subTest(executable=relative, mode=f"{mode:04o}"), \
                        tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary)
                    archive = self.make_archive(root, modes={relative: mode})
                    # A cluster helper without every execute bit already fails its own check.
                    with self.assertRaisesRegex(ValueError, f"has mode {mode:04o}|is not executable"):
                        VALIDATION.unpack(argparse.Namespace(archive=archive, output=root / "output",
                            source_sha="test-source", version="test-version"))

    def test_executable_modes_cover_every_macho_file_and_refuse_links(self):
        for scenario in ["valid", "extra-macho", "missing-fan", "fan-symlink"]:
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory() as temporary:
                app = Path(temporary) / PROD_NAMES["appBundleName"]
                write_app_with_cluster_helpers(app)
                for path in self.executable_paths(app)[:3]:
                    path.write_bytes(MACHO_ARM64)
                    path.chmod(0o755)
                fan = app / "Contents/Helpers" / VALIDATION.FAN_HELPER
                if scenario == "extra-macho":
                    (app / "Contents/Resources/tool").write_bytes(MACHO_ARM64)
                    (app / "Contents/Resources/tool").chmod(0o644)
                if scenario == "missing-fan":
                    fan.unlink()
                if scenario == "fan-symlink":
                    fan.unlink()
                    fan.symlink_to(app / "Contents/Helpers/darkbloom-cluster-worker")
                if scenario == "valid":
                    VALIDATION.check_executable_modes(app, VALIDATION.packaging(release_identity.DOCUMENT, PROD))
                else:
                    with self.assertRaisesRegex(ValueError, "Resources/tool has mode 0644|not a regular file"):
                        VALIDATION.check_executable_modes(app, VALIDATION.packaging(release_identity.DOCUMENT, PROD))

    def test_release_signing_copy_keeps_executable_modes_under_umask_077(self):
        release = (ROOT / ".github/workflows/release-provider.yml").read_text()
        step = release.split("- name: Stage bundle and smoke it before signing", 1)[1].split("\n      - name:", 1)[0]
        copy = next(line.strip() for line in step.splitlines() if '"$UNSIGNED_ROOT/$APP_NAME" "$APP"' in line)
        check = 'provider-signing-validation.py executable-modes --app "$APP" --version "$VERSION"'
        self.assertIn(check, step)
        self.assertLess(step.index(copy), step.index(check))
        self.assertLess(step.index(check), step.index("runtime-smoke"))
        self.assertLess(release.index(check), release.index("- name: Import Developer ID certificate"))
        script = ROOT / "scripts/provider-signing-validation.py"
        for command, valid in [(copy, True), (copy.replace("cp -pR", "cp -R"), False)]:
            with self.subTest(command=command), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                unsigned = root / "qualified-unsigned"
                write_app_with_cluster_helpers(unsigned / PROD_NAMES["appBundleName"])
                for path in self.executable_paths(unsigned / PROD_NAMES["appBundleName"])[:3]:
                    path.write_bytes(MACHO_ARM64)
                    path.chmod(0o755)
                app = root / "bundle" / PROD_NAMES["appBundleName"]
                app.parent.mkdir()
                environment = dict(os.environ, UNSIGNED_ROOT=str(unsigned), APP_NAME=PROD_NAMES["appBundleName"],
                                   APP=str(app), VERSION=PROD)
                subprocess.run(["bash", "-c", "set -euo pipefail; umask 077; " + command], env=environment, check=True)
                result = subprocess.run([sys.executable, str(script), "executable-modes", "--app", str(app),
                                         "--version", PROD], capture_output=True, text=True)
                if valid:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual([path.stat().st_mode & 0o7777 for path in self.executable_paths(app)], [0o755] * 5)
                else:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("has mode 0700", result.stderr)

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
                             "name": names["appDisplayName"], "enclave": names["enclaveName"]}
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
        recorded = {"app": "Candidate.app", "executable": "candidate-cli", "name": "Candidate",
                    "enclave": "candidate-enclave"}
        for scenario, layout, packaging, valid in [
                ("recorded", recorded, packaged, True),
                ("layout-differs", dict(recorded, executable="other-cli"), packaged, False),
                ("unsafe-name", recorded, dict(packaged, appBundleName="../Candidate.app"), False)]:
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

    # codesign stand-in for the synthetic app, whose executables are only Mach-O
    # headers: prints the entitlements recorded for the file it is asked about,
    # and fails like codesign for an unsigned one.
    CODESIGN_STUB = """#!/usr/bin/env python3
import json, os, sys
signed = json.load(open(os.environ["STUB_ENTITLEMENTS"]))
kinds = json.load(open(os.environ["STUB_SIGNATURES"]))
path = sys.argv[-1]
if path not in signed:
    sys.exit("code object is not signed at all")
if "-dv" in sys.argv:
    directory = {"developer-id": "flags=0x10000(runtime)", "other-team": "flags=0x10000(runtime)",
                 "adhoc": "flags=0x2(adhoc)", "linker-signed": "flags=0x20002(adhoc,linker-signed)"}
    kind = kinds.get(path, "developer-id")
    lines = ["Executable=" + path, "CodeDirectory v=20500 size=1 " + directory[kind] + " hashes=1+7 location=embedded"]
    if kind in ("adhoc", "linker-signed"):
        lines += ["Signature=adhoc", "TeamIdentifier=not set"]
    else:
        lines += ["Authority=Developer ID Application", "TeamIdentifier=" + ("SLDQ2GJ6TL" if kind == "developer-id" else "OTHERTEAM1")]
    sys.stderr.write("\\n".join(lines) + "\\n")
    sys.exit(0)
sys.stdout.write(signed[path])
"""

    def write_signed_app(self, root):
        """An app with the CLI, the enclave and fan helpers, and both cluster helpers."""
        app = root / "Darkbloom.app"
        write_app_with_cluster_helpers(app)
        for name in ["MacOS/darkbloom", "MacOS/darkbloom-enclave", "Helpers/darkbloom-fan-helper"]:
            (app / "Contents" / name).write_bytes(MACHO_ARM64)
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "darkbloom"}))
        return app

    def check_bundle_with_stub(self, app, entitlements, signatures=None):
        directory = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, directory)
        stub = directory / "codesign"
        stub.write_text(self.CODESIGN_STUB)
        stub.chmod(0o755)
        (directory / "signed.json").write_text(json.dumps(
            {str(app / "Contents" / name): value for name, value in entitlements.items()}))
        (directory / "signatures.json").write_text(json.dumps(
            {str(app / "Contents" / name): kind for name, kind in (signatures or {}).items()}))
        environment = {"PATH": f"{directory}:{os.environ['PATH']}",
                       "STUB_ENTITLEMENTS": str(directory / "signed.json"),
                       "STUB_SIGNATURES": str(directory / "signatures.json")}
        with mock.patch.dict(os.environ, environment), mock.patch("sys.stdout", new=io.StringIO()):
            VALIDATION.bundle_entitlements(argparse.Namespace(app=app))

    def test_bundle_entitlements_cover_every_executable_in_the_app(self):
        network = plistlib.dumps({"com.apple.security.network.client": True}).decode()
        executables = ["MacOS/darkbloom", "MacOS/darkbloom-enclave", "Helpers/darkbloom-fan-helper",
                       "Helpers/darkbloom-cluster-worker", "Helpers/darkbloom-cluster-plan"]
        refused = [("debug", plistlib.dumps({"com.apple.security.get-task-allow": True}).decode()),
                   ("legacy-debug", plistlib.dumps({"get-task-allow": True}).decode()),
                   ("malformed-debug", plistlib.dumps({"get-task-allow": "false"}).decode()),
                   ("unsigned", None)]
        with tempfile.TemporaryDirectory() as temporary:
            app = self.write_signed_app(Path(temporary))
            # The fan helper is signed with no entitlements at all.
            clean = {name: network for name in executables} | {"Helpers/darkbloom-fan-helper": ""}
            self.check_bundle_with_stub(app, clean)
            for name in executables:
                for scenario, value in refused:
                    with self.subTest(executable=name, scenario=scenario):
                        entitlements = dict(clean)
                        if value is None:
                            del entitlements[name]
                            expected = "is not signed"
                        else:
                            entitlements[name] = value
                            expected = "enables or malforms get-task-allow"
                        with self.assertRaisesRegex(ValueError, f"Contents/{name} {expected}"):
                            self.check_bundle_with_stub(app, entitlements)
                # A signature that is not the team's Developer ID: ad hoc, the linker's own, another team's.
                for kind in ("adhoc", "linker-signed", "other-team"):
                    with self.subTest(executable=name, signature=kind):
                        with self.assertRaisesRegex(ValueError, f"Contents/{name} is not signed by the Developer ID"):
                            self.check_bundle_with_stub(app, clean, {name: kind})

    def test_bundle_entitlements_require_the_main_executable(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = self.write_signed_app(Path(temporary))
            (app / "Contents/MacOS/darkbloom").write_bytes(b"#!/bin/sh\n")
            with self.assertRaisesRegex(ValueError, "Contents/MacOS/darkbloom is not a Mach-O executable"):
                self.check_bundle_with_stub(app, {})

    @unittest.skipUnless(sys.platform == "darwin" and shutil.which("codesign") and shutil.which("clang"),
                         "needs macOS codesign and clang")
    def test_bundle_entitlements_read_real_signatures(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = root / "Darkbloom.app"
            for directory in ["MacOS", "Helpers"]:
                (app / "Contents" / directory).mkdir(parents=True)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "darkbloom"}))
            (root / "main.c").write_text("int main(void) { return 0; }\n")
            debug = root / "debug.plist"
            debug.write_bytes(plistlib.dumps({"com.apple.security.get-task-allow": True}))
            names = ["Helpers/darkbloom-fan-helper", "Helpers/darkbloom-cluster-worker",
                     "Helpers/darkbloom-cluster-plan", "MacOS/darkbloom-enclave", "MacOS/darkbloom"]
            for name in names:
                subprocess.run(["clang", "-o", str(app / "Contents" / name), str(root / "main.c")], check=True)
            # Only the linker's signature (arm64 always has one): not the Developer ID.
            linked = app / "Contents/Helpers/darkbloom-fan-helper"
            self.assertEqual(VALIDATION.developer_id_problem(linked), "is not signed by the Developer ID")
            # An ad-hoc signature is not the Developer ID either; its entitlements are still read exactly.
            worker = app / "Contents/Helpers/darkbloom-cluster-worker"
            subprocess.run(["codesign", "--force", "--options", "runtime", "--sign", "-", str(worker)],
                           check=True, capture_output=True)
            self.assertEqual(VALIDATION.developer_id_problem(worker), "is not signed by the Developer ID")
            self.assertIsNone(VALIDATION.entitlement_problem(worker))
            subprocess.run(["codesign", "--force", "--options", "runtime", "--entitlements", str(debug),
                            "--sign", "-", str(worker)], check=True, capture_output=True)
            self.assertEqual(VALIDATION.entitlement_problem(worker), "enables or malforms get-task-allow")
            with self.assertRaisesRegex(ValueError, "Contents/Helpers/darkbloom-fan-helper is not signed by the Developer ID"), \
                    mock.patch("sys.stdout", new=io.StringIO()):
                VALIDATION.bundle_entitlements(argparse.Namespace(app=app))

    def test_release_checks_every_executable_after_signing_and_before_notarization(self):
        release = (ROOT / ".github/workflows/release-provider.yml").read_text()
        signed = release.index('--sign "$DEVELOPER_ID" "$APP"\n')
        check = release.index('provider-signing-validation.py bundle-entitlements --app "$APP"')
        notarize = release.index("xcrun notarytool submit")
        self.assertLess(signed, check)
        self.assertLess(check, notarize)

    def test_signing_validation_checks_every_executable_after_signing_and_before_notarization(self):
        validation = (ROOT / ".github/workflows/provider-signing-validation.yml").read_text()
        signed = validation.index('--sign "$DEVELOPER_ID" "$app"\n')
        check = validation.index('provider-signing-validation.py bundle-entitlements --app "$app"')
        notarize = validation.index("xcrun notarytool submit")
        self.assertLess(signed, check)
        self.assertLess(check, notarize)


if __name__ == "__main__":
    unittest.main()
