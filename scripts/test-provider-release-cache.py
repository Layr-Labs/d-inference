#!/usr/bin/env python3
"""Offline tests for cache compatibility and content-verified timestamp reuse."""

from copy import deepcopy
from contextlib import redirect_stderr
import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from provider_release_cache import identity, mtimes
from provider_release_cache.tracked import inventory


SCRIPT = Path(__file__).resolve().with_name("provider-release-cache.py")


def git(root, *arguments):
    return subprocess.check_output(
        ["git", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null",
         "-c", "protocol.file.allow=always", "-C", str(root), *arguments],
        stderr=subprocess.PIPE, text=True,
    ).strip()


def init_repo(root):
    root.mkdir(parents=True, exist_ok=True)
    git(root, "init", "-q")
    git(root, "config", "user.email", "cache-test@example.invalid")
    git(root, "config", "user.name", "Cache Test")


def commit(root):
    git(root, "add", ".")
    git(root, "commit", "-qm", "fixture")


class RepositoryFixture(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="provider-cache-tests-")
        self.addCleanup(temporary.cleanup)
        self.temporary = Path(temporary.name).resolve()
        self.root = self.temporary / "checkout"
        init_repo(self.root)
        self.write(".gitignore", ".build/\ntarget/\n")
        self.write("provider-swift/Package.swift", "// manifest\n")
        self.write("provider-swift/Package.resolved", '{"pins":[]}\n')
        self.write("provider-swift/Sources/main.swift", 'print("before")\n')
        self.write("coordinator/promptsidecar/Cargo.lock", "# lock\n")
        self.write("coordinator/promptsidecar/Cargo.toml", '[package]\nname="test"\n')
        self.write("scripts/provider-release-cache.py", "# helper\n")
        self.write("scripts/provider_release_cache/identity.py", "# key recipe\n")
        self.write("scripts/provider-release-swift.sh", "# wrapper\n")
        self.write(".github/actions/provider-release-build/action.yml", "# build recipe\n")
        commit(self.root)
        self.metadata = {
            "os": "Darwin", "arch": "arm64", "os_version": "26.0", "os_build": "25A100",
            "swift": {"version": "Apple Swift version 6.4 (swiftlang-build)\nTarget: arm64",
                      "binary": {"sha256": "compiler-bytes", "path": "/tools/usr/bin/swift"},
                      "target": {"target": {"triple": "arm64-apple-macosx26.0"}}},
            "sdk": {"version": "27.0", "build": "26A100", "path": "/tools/SDKs/MacOSX27.0.sdk",
                    "files": {"SDKSettings.json": {"sha256": "settings-bytes"}}},
            "xcode": {"version": "Xcode 27.0\nBuild version 18A100", "developer_dir": "/Xcode"},
            "rust": {"version": "rustc 1.88.0 (abc 2025-06-23)\ncommit-hash: abc",
                     "compiler": {"sha256": "rust-bytes"}},
            "build_env": {"MACOSX_DEPLOYMENT_TARGET": "14.0"},
        }

    def write(self, relative, contents):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents)
        return path

    def keys(self, lane="qualification", metadata=None, root=None):
        return identity.keys(root or self.root, lane, metadata or self.metadata)


class CacheIdentityTests(RepositoryFixture):
    def test_identical_inputs_have_identical_keys_and_narrow_prefixes(self):
        first = self.keys()
        self.assertEqual(first, self.keys())
        sha = git(self.root, "rev-parse", "HEAD")
        for kind in ("swift", "rust"):
            self.assertEqual(first[f"{kind}-key"], first[f"{kind}-prefix"] + sha)
            self.assertLess(len(first[f"{kind}-key"]), 512)
            self.assertEqual(first[f"{kind}-prefix"].count("\n"), 0)

    def test_source_commit_is_only_an_immutable_generation_suffix(self):
        before = self.keys()
        self.write("provider-swift/Sources/main.swift", 'print("after")\n')
        commit(self.root)
        after = self.keys()
        for kind in ("swift", "rust"):
            self.assertEqual(before[f"{kind}-prefix"], after[f"{kind}-prefix"])
            self.assertNotEqual(before[f"{kind}-key"], after[f"{kind}-key"])

    def test_toolchain_sdk_arch_os_flags_and_paths_split_compatibility(self):
        before = self.keys()
        changes = [
            ("swift", "version"), ("swift", "binary", "sha256"),
            ("swift", "binary", "path"), ("swift", "target", "target", "triple"),
            ("sdk", "version"), ("sdk", "build"), ("sdk", "path"),
            ("sdk", "files", "SDKSettings.json", "sha256"),
            ("arch",), ("os",), ("os_version",), ("os_build",),
            ("xcode", "version"), ("xcode", "developer_dir"),
            ("rust", "version"), ("rust", "compiler", "sha256"),
            ("build_env", "MACOSX_DEPLOYMENT_TARGET"),
        ]
        for path in changes:
            with self.subTest(path=path):
                metadata = deepcopy(self.metadata)
                field = metadata
                for component in path[:-1]:
                    field = field[component]
                field[path[-1]] += "changed"
                after = self.keys(metadata=metadata)
                self.assertNotEqual(before["swift-prefix"], after["swift-prefix"])
                self.assertNotEqual(before["rust-prefix"], after["rust-prefix"])

    def test_checkout_path_and_lane_are_boundaries(self):
        before = self.keys()
        other = self.temporary / "other-checkout"
        shutil.copytree(self.root, other)
        self.assertNotEqual(before["swift-prefix"], self.keys(root=other)["swift-prefix"])
        release = self.keys(lane="release")
        self.assertNotEqual(before["swift-prefix"], release["swift-prefix"])
        self.assertNotIn("rust-key", release)

    def test_manifests_locks_helper_wrapper_and_action_split_compatibility(self):
        before = self.keys()
        for relative in (
            "provider-swift/Package.swift", "provider-swift/Package.resolved",
            "coordinator/promptsidecar/Cargo.lock", "coordinator/promptsidecar/Cargo.toml",
            "scripts/provider-release-cache.py", "scripts/provider_release_cache/identity.py",
            "scripts/provider-release-swift.sh", ".github/actions/provider-release-build/action.yml",
        ):
            with self.subTest(relative=relative):
                path = self.root / relative
                previous = path.read_text()
                path.write_text(previous + "changed\n")
                self.assertNotEqual(before["swift-prefix"], self.keys()["swift-prefix"])
                path.write_text(previous)

    def test_recursive_gitlink_changes_split_compatibility(self):
        leaf = self.temporary / "leaf"
        init_repo(leaf)
        (leaf / "kernel.cpp").write_text("// first\n")
        commit(leaf)
        library = self.temporary / "library"
        init_repo(library)
        git(library, "submodule", "add", "-q", str(leaf), "nested")
        commit(library)
        git(self.root, "submodule", "add", "-q", str(library), "libs/library")
        git(self.root, "submodule", "update", "--init", "--recursive", "-q")
        commit(self.root)
        before = self.keys()
        tracked = inventory(self.root)
        self.assertEqual(set(tracked.gitlinks), {"libs/library", "libs/library/nested"})
        self.assertIn("libs/library/nested/kernel.cpp", tracked.files)
        nested = self.root / "libs/library/nested"
        git(nested, "config", "user.email", "cache-test@example.invalid")
        git(nested, "config", "user.name", "Cache Test")
        (nested / "kernel.cpp").write_text("// second\n")
        commit(nested)
        with self.assertRaisesRegex(ValueError, "differs from recorded gitlink"):
            self.keys()
        checked_library = self.root / "libs/library"
        git(checked_library, "config", "user.email", "cache-test@example.invalid")
        git(checked_library, "config", "user.name", "Cache Test")
        commit(checked_library)
        commit(self.root)
        self.assertNotEqual(before["swift-prefix"], self.keys()["swift-prefix"])
        mtimes.snapshot(self.root)
        manifest = mtimes.read_manifest(self.root)
        self.assertIn("libs/library/nested/kernel.cpp", {entry["path"] for entry in manifest})


class SelectedToolchainTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="provider-cache-tools-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.swift = self.root / "toolchain/usr/bin/swift"
        self.clang = self.root / "xcode/usr/bin/clang"
        self.sdk = self.root / "sdk"
        self.rust = self.root / "rust"
        for path in (self.swift, self.clang, self.rust / "bin/rustc", self.rust / "bin/cargo"):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("tool bytes\n")
        self.sdk.mkdir()
        (self.sdk / "SDKSettings.json").write_text('{"Version":"27.0","CanonicalName":"macosx27.0"}')
        self.commands = {
            (str(self.swift), "--version"): "Apple Swift version 6.4 (build1)",
            (str(self.swift), "-print-target-info"): '{"target":{"triple":"arm64-apple-macosx26.0"}}',
            ("xcrun", "--sdk", str(self.sdk), "--find", "clang"): str(self.clang),
            (str(self.clang), "--version"): "Apple clang version 18.0.0",
            ("sw_vers", "-productVersion"): "26.0",
            ("sw_vers", "-buildVersion"): "25A100",
            ("xcodebuild", "-version"): "Xcode 27.0\nBuild version 18A100",
            ("xcode-select", "-p"): "/Applications/Xcode.app/Contents/Developer",
            ("rustc", "+1.88.0", "--print", "sysroot"): str(self.rust),
            ("rustc", "+1.88.0", "--version", "--verbose"): "rustc 1.88.0 (abc)\ncommit-hash: abc",
            ("cargo", "+1.88.0", "--version"): "cargo 1.88.0 (abc)",
        }
        environment = {"PROVIDER_SWIFT": str(self.swift), "PROVIDER_SDKROOT": str(self.sdk)}
        self.enterContext(patch.dict(os.environ, environment, clear=True))
        self.probe = self.enterContext(patch.object(identity, "command", side_effect=lambda *args: self.commands[args]))
        self.enterContext(patch.object(identity.platform, "system", return_value="Darwin"))
        self.enterContext(patch.object(identity.platform, "machine", return_value="arm64"))

    def test_selected_binary_and_sdk_bytes_affect_identity_at_same_version(self):
        first = identity.toolchain_metadata("qualification")
        self.swift.write_text("different compiler, same version string\n")
        second = identity.toolchain_metadata("qualification")
        self.assertNotEqual(identity.digest(first), identity.digest(second))
        self.assertEqual(first["swift"]["version"], second["swift"]["version"])
        (self.sdk / "SDKSettings.json").write_text('{"Version":"27.0","CanonicalName":"updated-sdk"}')
        third = identity.toolchain_metadata("qualification")
        self.assertNotEqual(identity.digest(second), identity.digest(third))
        self.assertIn(("rustc", "+1.88.0", "--version", "--verbose"),
                      [call.args for call in self.probe.call_args_list])

    def test_release_does_not_require_or_probe_rust(self):
        metadata = identity.toolchain_metadata("release")
        self.assertNotIn("rust", metadata)
        self.assertFalse(any(call.args[0] in {"rustc", "cargo"} for call in self.probe.call_args_list))

    def test_frontend_bytes_are_checked_independently_of_driver(self):
        frontend = self.swift.with_name("swift-frontend")
        frontend.write_text("compiler frontend\n")
        first = identity.toolchain_metadata("release")
        frontend.write_text("updated frontend\n")
        second = identity.toolchain_metadata("release")
        self.assertEqual(first["swift"]["binary"], second["swift"]["binary"])
        self.assertNotEqual(first["swift"]["components"], second["swift"]["components"])

    def test_clt_sdk_build_uses_local_metadata_when_xcrun_rejects_sdk(self):
        system_version = self.sdk / "System/Library/CoreServices/SystemVersion.plist"
        system_version.parent.mkdir(parents=True)
        system_version.write_bytes(plistlib.dumps({"ProductBuildVersion": "26A100"}))

        def probe(*arguments):
            if arguments[-1] == "--show-sdk-build-version":
                raise subprocess.CalledProcessError(1, arguments, stderr="SDK cannot be located")
            return self.commands[arguments]

        self.probe.side_effect = probe
        metadata = identity.toolchain_metadata("release")
        self.assertEqual(metadata["sdk"]["build"], "26A100")
        self.assertEqual(metadata["sdk"]["build_source"],
                         "System/Library/CoreServices/SystemVersion.plist:ProductBuildVersion")
        self.assertFalse(any(call.args[-1] == "--show-sdk-build-version"
                             for call in self.probe.call_args_list))

    def test_sdk_settings_build_label_is_used_without_system_version(self):
        (self.sdk / "SDKSettings.json").write_text('{"Version":"27.0","ProductBuildVersion":"26A101"}')
        metadata = identity.sdk_metadata(self.sdk)
        self.assertEqual(metadata["build"], "26A101")
        self.assertEqual(metadata["build_source"], "SDKSettings.json:ProductBuildVersion")

    def test_sdk_without_build_label_uses_explicit_metadata_digest(self):
        first = identity.sdk_metadata(self.sdk)
        self.assertEqual(first["build_source"], "metadata-content-digest")
        self.assertRegex(first["build"], r"^metadata-sha256:[0-9a-f]{64}$")
        (self.sdk / "SDKSettings.json").write_text('{"Version":"27.0","CanonicalName":"updated-sdk"}')
        second = identity.sdk_metadata(self.sdk)
        self.assertNotEqual(first["build"], second["build"])

    def test_invalid_sdk_metadata_is_not_silently_downgraded(self):
        (self.sdk / "SDKSettings.plist").write_text("broken plist")
        with self.assertRaises(plistlib.InvalidFileException):
            identity.sdk_metadata(self.sdk)


class SourceTimestampTests(RepositoryFixture):
    def setUp(self):
        super().setUp()
        self.source = self.root / "provider-swift/Sources/main.swift"
        self.original_ns = 1_700_000_000_123_456_789
        self.fresh_ns = self.original_ns + 60_000_000_000
        os.utime(self.source, ns=(self.original_ns, self.original_ns))
        mtimes.snapshot(self.root)
        self.manifest_path = self.root / "provider-swift/.build" / mtimes.MANIFEST
        self.manifest = json.loads(self.manifest_path.read_text())
        os.utime(self.source, ns=(self.fresh_ns, self.fresh_ns))

    def restore_manifest(self, payload):
        self.manifest_path.write_text(json.dumps(payload))
        warnings = io.StringIO()
        with redirect_stderr(warnings):
            result = mtimes.restore(self.root)
        return result, warnings.getvalue()

    def test_unchanged_file_recovers_exact_nanosecond_mtime(self):
        contents = self.source.read_bytes()
        index = (self.root / ".git/index").read_bytes()
        result = mtimes.restore(self.root)
        self.assertGreater(result["restored"], 0)
        self.assertEqual(self.source.stat().st_mtime_ns, self.original_ns)
        self.assertEqual(self.source.read_bytes(), contents)
        self.assertEqual((self.root / ".git/index").read_bytes(), index)
        self.assertEqual(git(self.root, "status", "--porcelain"), "")

    def test_changed_deleted_and_new_files_keep_current_state(self):
        self.source.write_text('print("change")\n')
        os.utime(self.source, ns=(self.fresh_ns, self.fresh_ns))
        deleted = self.root / "provider-swift/Package.swift"
        deleted.unlink()
        new = self.write("provider-swift/Sources/new.swift", "// newly tracked\n")
        git(self.root, "add", "provider-swift/Sources/new.swift")
        os.utime(new, ns=(self.fresh_ns, self.fresh_ns))
        mtimes.restore(self.root)
        self.assertEqual(self.source.stat().st_mtime_ns, self.fresh_ns)
        self.assertEqual(new.stat().st_mtime_ns, self.fresh_ns)
        self.assertFalse(deleted.exists())

    def test_untracked_file_in_well_formed_manifest_is_not_touched(self):
        untracked = self.write("private-untracked", "identical text")
        os.utime(untracked, ns=(self.fresh_ns, self.fresh_ns))
        self.manifest["files"].append({"path": "private-untracked",
                                      "sha256": hashlib.sha256(untracked.read_bytes()).hexdigest(),
                                      "mtime_ns": self.original_ns})
        self.restore_manifest(self.manifest)
        self.assertEqual(untracked.stat().st_mtime_ns, self.fresh_ns)

    def test_symlink_file_or_ancestor_cannot_reach_outside_checkout(self):
        external = self.temporary / "external.swift"
        external.write_bytes(self.source.read_bytes())
        os.utime(external, ns=(self.fresh_ns, self.fresh_ns))
        self.source.unlink()
        self.source.symlink_to(external)
        mtimes.restore(self.root)
        self.assertEqual(external.stat().st_mtime_ns, self.fresh_ns)
        self.source.unlink()
        self.source.parent.rmdir()
        outside = self.temporary / "sources"
        outside.mkdir()
        external.rename(outside / "main.swift")
        self.source.parent.symlink_to(outside, target_is_directory=True)
        mtimes.restore(self.root)
        self.assertEqual((outside / "main.swift").stat().st_mtime_ns, self.fresh_ns)

    def test_snapshot_excludes_symlinks_untracked_outputs_and_git_metadata(self):
        self.write("untracked", "secret")
        self.write("provider-swift/.build/objects", "object")
        self.write("coordinator/promptsidecar/target/binary", "binary")
        self.write("tracked-link", "placeholder")
        git(self.root, "add", "tracked-link")
        (self.root / "tracked-link").unlink()
        (self.root / "tracked-link").symlink_to(self.source)
        mtimes.snapshot(self.root)
        paths = {entry["path"] for entry in mtimes.read_manifest(self.root)}
        self.assertFalse(paths & {"untracked", "tracked-link", "provider-swift/.build/objects",
                                  "coordinator/promptsidecar/target/binary", ".git/index"})

    def test_hardlink_cannot_change_an_external_files_timestamp(self):
        external = self.temporary / "hardlinked-source"
        os.link(self.source, external)
        mtimes.restore(self.root)
        self.assertEqual(external.stat().st_mtime_ns, self.fresh_ns)

    def test_unsafe_entry_invalidates_whole_manifest_before_any_restore(self):
        for unsafe in ("../external", "/tmp/external", ".git/HEAD", "provider-swift/.build/object",
                       "coordinator/promptsidecar/target/binary", "a//b", "a/../b", "a\\b", "a\nb"):
            with self.subTest(unsafe=unsafe):
                payload = deepcopy(self.manifest)
                payload["files"].append({"path": unsafe, "sha256": "0" * 64,
                                         "mtime_ns": self.original_ns})
                result, warning = self.restore_manifest(payload)
                self.assertEqual(result["restored"], 0)
                self.assertIn("Ignoring cached source timestamps", warning)
                self.assertEqual(self.source.stat().st_mtime_ns, self.fresh_ns)

    def test_malformed_schema_hash_timestamp_duplicates_and_root_fail_safe(self):
        payloads = [{}, [], {**self.manifest, "schema": 2}, {**self.manifest, "schema": True},
                    {**self.manifest, "root": "/different/checkout"}]
        for field, value in (("sha256", "invalid"), ("mtime_ns", -1), ("mtime_ns", True),
                             ("mtime_ns", 2**64), ("path", 17)):
            payload = deepcopy(self.manifest)
            payload["files"][0][field] = value
            payloads.append(payload)
        duplicate = deepcopy(self.manifest)
        duplicate["files"].append(duplicate["files"][0])
        payloads.append(duplicate)
        for payload in payloads:
            with self.subTest(payload=payload):
                result, warning = self.restore_manifest(payload)
                self.assertEqual(result["restored"], 0)
                self.assertTrue(warning)
                self.assertEqual(self.source.stat().st_mtime_ns, self.fresh_ns)

    def test_corrupt_or_missing_manifest_is_successful_noop(self):
        self.manifest_path.write_text("{broken")
        result = subprocess.run(["python3", str(SCRIPT), "restore-mtimes", "--root", str(self.root)],
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("warning:", result.stderr)
        self.assertEqual(self.source.stat().st_mtime_ns, self.fresh_ns)
        self.manifest_path.unlink()
        self.assertEqual(mtimes.restore(self.root), {"restored": 0, "skipped": 0})

    def test_manifest_symlink_is_rejected_without_reading_external_target(self):
        external = self.temporary / "manifest.json"
        self.manifest_path.rename(external)
        self.manifest_path.symlink_to(external)
        warnings = io.StringIO()
        with redirect_stderr(warnings):
            result = mtimes.restore(self.root)
        self.assertEqual(result["restored"], 0)
        self.assertIn("warning:", warnings.getvalue())
        self.assertEqual(self.source.stat().st_mtime_ns, self.fresh_ns)


if __name__ == "__main__":
    unittest.main()
