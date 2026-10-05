#!/usr/bin/env python3
"""Offline cache-key tests using local Git fixtures and mocked tool metadata."""

from contextlib import redirect_stderr, redirect_stdout
from copy import deepcopy
import importlib.util
import io
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from provider_release_cache import identity


SCRIPT = Path(__file__).resolve().with_name("provider-ci-cache.py")
SPEC = importlib.util.spec_from_file_location("provider_ci_cache", SCRIPT)
cache = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(cache)


def git(root, *arguments):
    return subprocess.check_output(
        ["git", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null",
         "-c", "protocol.file.allow=always", "-C", str(root), *arguments],
        text=True, stderr=subprocess.PIPE,
    ).strip()


def init_repo(root):
    root.mkdir(parents=True, exist_ok=True)
    git(root, "init", "-q")
    git(root, "config", "user.email", "cache-test@example.invalid")
    git(root, "config", "user.name", "Cache Test")


def commit(root):
    git(root, "add", ".")
    git(root, "commit", "-qm", "fixture")


class CacheIdentityTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="provider-ci-cache-tests-")
        self.addCleanup(temporary.cleanup)
        self.temporary = Path(temporary.name).resolve()
        self.root = self.temporary / "checkout"
        init_repo(self.root)
        self.write(".gitignore", ".build/\ntarget/\n")
        self.write("provider-swift/Package.swift", "// manifest\n")
        self.write("provider-swift/Package.resolved", '{"pins":[]}\n')
        self.write("provider-swift/Sources/main.swift", 'print("before")\n')
        self.write("coordinator/promptsidecar/Cargo.toml", '[package]\nname="fixture"\n')
        self.write("coordinator/promptsidecar/Cargo.lock", "# locked\n")
        for path in cache.RECIPE_PATHS:
            self.write(path, "# recipe\n")
        for name in ("identity", "tracked", "descriptors", "mtimes", "__init__"):
            self.write(f"scripts/provider_release_cache/{name}.py", "# shared helper\n")

        # The native MLX gitlink is nested under mlx-swift, not libs/mlx.
        native = self.root / cache.MLX_SOURCE
        init_repo(native)
        (native / "kernel.cpp").write_text("// native kernel\n")
        commit(native)
        swift = self.root / "libs/mlx-swift"
        init_repo(swift)
        (swift / "Package.swift").write_text("// mlx-swift manifest\n")
        (swift / ".gitmodules").write_text('[submodule "native"]\npath=Source/Cmlx/mlx\nurl=./native\n')
        commit(swift)
        top_level = self.root / "libs/mlx"
        init_repo(top_level)
        (top_level / "kernel.cpp").write_text("// top-level kernel\n")
        commit(top_level)
        self.write(".gitmodules", '[submodule "swift"]\npath=libs/mlx-swift\nurl=./swift\n'
                   '[submodule "mlx"]\npath=libs/mlx\nurl=./mlx\n')
        commit(self.root)
        self.metadata = {
            "os": "Darwin", "arch": "arm64", "os_version": "26.2", "os_build": "25C100",
            "swift": {"version": "Apple Swift version 6.4 (build)\nTarget: arm64",
                      "binary": {"sha256": "swift-bytes", "path": "/tools/swift"},
                      "target": {"target": {"triple": "arm64-apple-macosx26.2"}}},
            "sdk": {"version": "27.0", "build": "26A100", "path": "/sdk/MacOSX27.sdk",
                    "files": {"SDKSettings.json": {"sha256": "sdk-bytes"}}},
            "xcode": {"version": "Xcode 27.0\nBuild version 18A100", "developer_dir": "/Xcode",
                      "clang": {"sha256": "clang-bytes"}},
            "metal": {"version": "Apple metal version 32023.42",
                      "compiler": {"sha256": "metal-bytes"}},
            "rust": {"version": "rustc 1.88.0 (abc)\ncommit-hash: abc",
                     "compiler": {"sha256": "rust-bytes"}},
            "build_env": {"MACOSX_DEPLOYMENT_TARGET": "14.0",
                          "MLX_METALLIB_DEPLOYMENT_TARGET": "26.2"},
        }
        self.metadata["metallib_sdk"] = deepcopy(self.metadata["sdk"])
        # A missing injection must fail rather than invoke a real toolchain.
        self.enterContext(patch.object(cache, "toolchain_metadata", side_effect=AssertionError("real probe")))

    def write(self, relative, contents):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents)
        return path

    def keys(self, lane="provider", metadata=None, root=None):
        return cache.keys(root or self.root, lane, metadata if metadata is not None else self.metadata)

    def test_deterministic_keys_have_only_compatible_restore_prefixes(self):
        for lane in cache.LANE_PURPOSES:
            with self.subTest(lane=lane):
                outputs = self.keys(lane)
                self.assertEqual(outputs, self.keys(lane))
                for kind in (("swift", "rust") if lane in ("parity", "integration") else ("swift",)):
                    self.assertEqual(outputs[f"{kind}-key"], outputs[f"{kind}-prefix"]
                                     + git(self.root, "rev-parse", "HEAD"))
                    self.assertLess(len(outputs[f"{kind}-key"]), 512)
                self.assertLess(len(outputs["metallib-key"]), 512)
                self.assertNotIn("metallib-prefix", outputs)
                self.assertTrue(all("\n" not in value for name, value in outputs.items()
                                    if name.endswith(("-key", "-prefix", "-digest"))))

    def test_source_commits_change_generations_not_prefixes_or_metallib(self):
        before = {lane: self.keys(lane) for lane in cache.LANE_PURPOSES}
        self.write("provider-swift/Sources/main.swift", 'print("after")\n')
        commit(self.root)
        for lane, previous in before.items():
            after = self.keys(lane)
            for kind in (("swift", "rust") if lane in ("parity", "integration") else ("swift",)):
                self.assertEqual(previous[f"{kind}-prefix"], after[f"{kind}-prefix"])
                self.assertNotEqual(previous[f"{kind}-key"], after[f"{kind}-key"])
            self.assertEqual(previous["metallib-key"], after["metallib-key"])

    def test_lanes_and_release_are_isolated_but_metallib_is_shared(self):
        outputs = [self.keys(lane) for lane in cache.LANE_PURPOSES]
        self.assertEqual(len({output["swift-prefix"] for output in outputs}), 4)
        self.assertNotEqual(self.keys("parity")["rust-prefix"], self.keys("integration")["rust-prefix"])
        self.assertEqual(len({output["metallib-key"] for output in outputs}), 1)
        for lane in ("release", "qualification"):
            release = identity.keys(self.root, lane, self.metadata)
            self.assertFalse(any(output["swift-key"].startswith(release["swift-prefix"])
                                 for output in outputs))
        for lane in ("provider", "sdk"):
            self.assertFalse(any(name.startswith("rust-") for name in self.keys(lane)))

    def test_toolchain_sdk_arch_os_and_flags_split_compatibility(self):
        before = {lane: self.keys(lane) for lane in ("provider", "integration")}
        sources = cache.tracked.inventory(self.root)
        changes = (
            ("swift", "version"), ("swift", "binary", "sha256"), ("swift", "binary", "path"),
            ("swift", "target", "target", "triple"), ("sdk", "version"), ("sdk", "build"),
            ("sdk", "path"), ("sdk", "files", "SDKSettings.json", "sha256"), ("arch",),
            ("os",), ("os_version",), ("os_build",), ("xcode", "version"),
            ("xcode", "developer_dir"), ("xcode", "clang", "sha256"),
            ("build_env", "MACOSX_DEPLOYMENT_TARGET"),
        )
        for path in changes:
            with self.subTest(path=path):
                metadata = deepcopy(self.metadata)
                field = metadata
                for name in path[:-1]:
                    field = field[name]
                field[path[-1]] += "changed"
                with patch.object(cache.tracked, "inventory", return_value=sources):
                    for lane, previous in before.items():
                        after = self.keys(lane, metadata=metadata)
                        self.assertNotEqual(previous["swift-prefix"], after["swift-prefix"])
                        if lane == "integration":
                            self.assertNotEqual(previous["rust-prefix"], after["rust-prefix"])

    def test_rust_metadata_affects_only_parity_and_integration(self):
        metadata = deepcopy(self.metadata)
        metadata["rust"]["compiler"]["sha256"] += "changed"
        for lane in cache.LANE_PURPOSES:
            before, after = self.keys(lane), self.keys(lane, metadata)
            if lane in ("parity", "integration"):
                self.assertNotEqual(before["swift-prefix"], after["swift-prefix"])
                self.assertNotEqual(before["rust-prefix"], after["rust-prefix"])
            else:
                self.assertEqual(before, after)
            self.assertEqual(before["metallib-key"], after["metallib-key"])

    def test_metal_version_and_compiler_bytes_split_all_build_and_metallib_keys(self):
        sources = cache.tracked.inventory(self.root)
        with patch.object(cache.tracked, "inventory", return_value=sources):
            for lane in cache.LANE_PURPOSES:
                before = self.keys(lane)
                for path in (("version",), ("compiler", "sha256")):
                    with self.subTest(lane=lane, path=path):
                        metadata = deepcopy(self.metadata)
                        field = metadata["metal"]
                        for name in path[:-1]:
                            field = field[name]
                        field[path[-1]] += "changed"
                        after = self.keys(lane, metadata)
                        self.assertNotEqual(before["toolchain-digest"], after["toolchain-digest"])
                        self.assertNotEqual(before["swift-prefix"], after["swift-prefix"])
                        self.assertNotEqual(before["metallib-key"], after["metallib-key"])
                        if lane in ("parity", "integration"):
                            self.assertNotEqual(before["rust-prefix"], after["rust-prefix"])

    def test_checkout_paths_split_objects_not_metallib(self):
        other = self.temporary / "other checkout"
        shutil.copytree(self.root, other)
        before, after = self.keys(), self.keys(root=other)
        self.assertNotEqual(before["swift-prefix"], after["swift-prefix"])
        self.assertEqual(before["metallib-key"], after["metallib-key"])
        alias = self.temporary / "alias"
        alias.symlink_to(self.root, target_is_directory=True)
        self.assertNotEqual(before["swift-prefix"], self.keys(root=alias)["swift-prefix"])

    def test_manifests_locks_ci_action_and_all_helper_bytes_split_objects(self):
        before = self.keys()
        sources = cache.tracked.inventory(self.root)
        paths = ("provider-swift/Package.swift", "provider-swift/Package.resolved",
                 "coordinator/promptsidecar/Cargo.toml", "coordinator/promptsidecar/Cargo.lock",
                 ".gitmodules", "libs/mlx-swift/.gitmodules", "libs/mlx-swift/Package.swift",
                 "scripts/provider_release_cache/identity.py",
                 "scripts/provider_release_cache/tracked.py", "scripts/provider_release_cache/mtimes.py",
                 *cache.RECIPE_PATHS)
        for relative in paths:
            with self.subTest(relative=relative):
                path = self.root / relative
                original = path.read_text()
                path.write_text(original + "changed\n")
                with patch.object(cache.tracked, "inventory", return_value=sources):
                    self.assertNotEqual(before["swift-prefix"], self.keys()["swift-prefix"])
                path.write_text(original)

    def test_new_shared_module_and_missing_composite_action_affect_recipe(self):
        before = self.keys()
        self.write("scripts/provider_release_cache/new_helper.py", "# additional helper\n")
        self.assertNotEqual(before["recipe-digest"], self.keys()["recipe-digest"])
        (self.root / "scripts/provider_release_cache/new_helper.py").unlink()
        (self.root / ".github/actions/provider-ci-build/action.yml").unlink()
        self.assertNotEqual(before["recipe-digest"], self.keys()["recipe-digest"])

    def test_integration_recipe_splits_only_integration_objects_not_shared_metal(self):
        before = {lane: self.keys(lane) for lane in cache.LANE_PURPOSES}
        self.write(".github/workflows/integration.yml", "# integration build changed\n")
        for lane, previous in before.items():
            after = self.keys(lane)
            self.assertEqual(previous["metallib-key"], after["metallib-key"])
            if lane == "integration":
                for kind in ("swift", "rust"):
                    self.assertNotEqual(previous[f"{kind}-prefix"], after[f"{kind}-prefix"])
            else:
                self.assertEqual(previous, after)

    def test_metallib_uses_actual_sdk_xcode_deployment_and_fetch_stage_hashes(self):
        before = self.keys()["metallib-key"]
        sources = cache.tracked.inventory(self.root)
        for path in (("metallib_sdk", "version"), ("metallib_sdk", "build"),
                     ("metallib_sdk", "files", "SDKSettings.json", "sha256"),
                     ("xcode", "version"), ("xcode", "clang", "sha256"), ("arch",),
                     ("build_env", "MLX_METALLIB_DEPLOYMENT_TARGET")):
            with self.subTest(path=path):
                metadata = deepcopy(self.metadata)
                field = metadata
                for name in path[:-1]:
                    field = field[name]
                field[path[-1]] += "changed"
                with patch.object(cache.tracked, "inventory", return_value=sources):
                    self.assertNotEqual(before, self.keys(metadata=metadata)["metallib-key"])
        for relative in cache.METALLIB_RECIPE_PATHS:
            path = self.root / relative
            original = path.read_text()
            path.write_text(original + "changed\n")
            self.assertNotEqual(before, self.keys()["metallib-key"])
            path.write_text(original)
        metadata = deepcopy(self.metadata)
        metadata["build_env"].pop("MLX_METALLIB_DEPLOYMENT_TARGET")
        self.assertEqual(before, self.keys(metadata=metadata)["metallib-key"])
        metadata["sdk"]["version"] += "different Swift SDK"
        metadata["swift"]["version"] += "different Swift toolchain"
        self.assertEqual(before, self.keys(metadata=metadata)["metallib-key"])
        self.write(".github/workflows/ci.yml", "# changed CI\n")
        self.assertEqual(before, self.keys()["metallib-key"])

    def test_native_recursive_gitlink_not_top_level_mlx_keys_metallib(self):
        before = self.keys()
        for relative in ("libs/mlx", cache.MLX_SOURCE):
            module = self.root / relative
            git(module, "config", "user.email", "cache-test@example.invalid")
            git(module, "config", "user.name", "Cache Test")
            (module / "kernel.cpp").write_text("// new kernel\n")
            commit(module)
            with self.assertRaisesRegex(ValueError, "differs from recorded gitlink"):
                self.keys()
            if relative == cache.MLX_SOURCE:
                parent = self.root / "libs/mlx-swift"
                git(parent, "config", "user.email", "cache-test@example.invalid")
                git(parent, "config", "user.name", "Cache Test")
                commit(parent)
            commit(self.root)
            after = self.keys()
            self.assertNotEqual(before["swift-prefix"], after["swift-prefix"])
            if relative == cache.MLX_SOURCE:
                self.assertNotEqual(before["metallib-key"], after["metallib-key"])
                self.assertEqual(after["mlx-sha"], git(module, "rev-parse", "HEAD"))
            else:
                self.assertEqual(before["metallib-key"], after["metallib-key"])

    def test_unknown_lane_and_missing_native_gitlink_fail_closed(self):
        with self.assertRaisesRegex(ValueError, "Unknown provider CI lane"):
            self.keys("release")
        sources = cache.tracked.inventory(self.root)
        sources.gitlinks.pop(cache.MLX_SOURCE)
        with patch.object(cache.tracked, "inventory", return_value=sources):
            with self.assertRaisesRegex(ValueError, "Native MLX source"):
                self.keys()


class ToolchainSelectionTests(unittest.TestCase):
    def setUp(self):
        self.enterContext(patch.dict(os.environ, {}, clear=True))
        self.commands = {
            ("xcrun", "--sdk", "macosx", "--find", "swift"): "/Xcode/usr/bin/swift",
            ("xcrun", "--sdk", "macosx", "--show-sdk-path"): "/Xcode/SDKs/MacOSX.sdk",
            ("xcrun", "--no-cache", "--sdk", "macosx", "--find", "metal"): "/mounted/Metal.xctoolchain/usr/bin/metal",
            ("xcrun", "--no-cache", "--sdk", "macosx", "metal", "--version"): "Apple metal version 32023.42",
        }
        self.probe = self.enterContext(patch.object(identity, "command", side_effect=lambda *args: self.commands[args]))
        self.sdk = self.enterContext(patch.object(identity, "sdk_metadata", return_value={"build": "sdk-build"}))
        self.which = self.enterContext(patch.object(cache.shutil, "which", return_value="/Xcode/usr/bin/swift"))
        self.external = self.enterContext(patch.object(identity, "external_file",
                                                      side_effect=lambda path: {"path": str(path), "sha256": "tool-bytes"}))

    def test_defaults_exist_only_during_probe_and_rust_is_for_rust_lanes(self):
        def selected(lane):
            self.assertEqual(os.environ["PROVIDER_SWIFT"], "/Xcode/usr/bin/swift")
            self.assertEqual(os.environ["PROVIDER_SDKROOT"], "/Xcode/SDKs/MacOSX.sdk")
            return {"lane": lane, "swift": {}}

        with patch.object(identity, "toolchain_metadata", side_effect=selected) as metadata:
            for lane in cache.LANE_PURPOSES:
                result = cache.toolchain_metadata(lane)
                self.assertEqual(result["lane"], "qualification" if lane in ("parity", "integration") else "release")
                self.assertEqual(result["metallib_sdk"], {"build": "sdk-build"})
                self.assertEqual(dict(os.environ), {})
            self.assertEqual([call.args for call in metadata.call_args_list],
                             [("release",), ("release",), ("qualification",), ("qualification",)])

    def test_explicit_overrides_are_preserved_and_default_metal_sdk_is_separate(self):
        os.environ.update({"PROVIDER_SWIFT": "/custom/swift", "PROVIDER_SDKROOT": "/custom/sdk",
                           "SDKROOT": "/custom/sdk", "DEVELOPER_DIR": "/custom/Xcode"})
        self.which.return_value = "/custom/swift"
        previous = dict(os.environ)
        with patch.object(identity, "toolchain_metadata", return_value={"swift": {}}) as metadata:
            cache.toolchain_metadata("provider")
        self.assertEqual(dict(os.environ), previous)
        metadata.assert_called_once_with("release")
        self.assertEqual([call.args for call in self.probe.call_args_list],
                         [("xcrun", "--sdk", "macosx", "--show-sdk-path"),
                          ("xcrun", "--no-cache", "--sdk", "macosx", "--find", "metal"),
                          ("xcrun", "--no-cache", "--sdk", "macosx", "metal", "--version")])
        self.sdk.assert_called_once_with(Path("/Xcode/SDKs/MacOSX.sdk"))

    def test_path_binary_and_sdkroot_variation_change_identity(self):
        def selected(lane):
            return {"swift": {"binary": identity.external_file(Path(os.environ["PROVIDER_SWIFT"]))},
                    "sdk": {"path": os.environ["PROVIDER_SDKROOT"]}}

        with patch.object(identity, "toolchain_metadata", side_effect=selected):
            before = cache.toolchain_metadata("provider")
            self.which.return_value = "/other/usr/bin/swift"
            changed_swift = cache.toolchain_metadata("provider")
            self.assertNotEqual(identity.digest(before), identity.digest(changed_swift))
            self.assertEqual(changed_swift["swift"]["invocation"]["path"], "/other/usr/bin/swift")
            os.environ["SDKROOT"] = "/other/sdk"
            changed_sdk = cache.toolchain_metadata("provider")
            self.assertNotEqual(identity.digest(changed_swift), identity.digest(changed_sdk))
            self.assertEqual(changed_sdk["sdk"]["path"], "/other/sdk")
            self.assertEqual(dict(os.environ), {"SDKROOT": "/other/sdk"})

    def test_prepared_metal_fingerprint_changes_for_version_and_bytes_not_mount(self):
        find = ("xcrun", "--no-cache", "--sdk", "macosx", "--find", "metal")
        version = ("xcrun", "--no-cache", "--sdk", "macosx", "metal", "--version")
        with patch.object(identity, "toolchain_metadata", side_effect=lambda lane: {"swift": {}}):
            before = cache.toolchain_metadata("provider")
            self.assertEqual(before["metal"], {"version": "Apple metal version 32023.42",
                                               "compiler": {"sha256": "tool-bytes"}})
            self.commands[find] = "/different-random-mount/Metal.xctoolchain/usr/bin/metal"
            self.commands[version] += "\nInstalledDir: /different-random-mount/Metal.xctoolchain/usr/bin"
            self.assertEqual(before, cache.toolchain_metadata("provider"))
            self.commands[version] = before["metal"]["version"] + " updated\nInstalledDir: /mount"
            self.assertNotEqual(identity.digest(before), identity.digest(cache.toolchain_metadata("provider")))
            self.commands[version] = before["metal"]["version"]
            self.external.side_effect = lambda path: {"path": str(path), "sha256":
                                                     "updated-bytes" if path.name == "metal" else "tool-bytes"}
            self.assertNotEqual(identity.digest(before), identity.digest(cache.toolchain_metadata("provider")))
            self.assertEqual(dict(os.environ), {})

    def test_unprepared_metal_probe_fails_and_restores_environment(self):
        def probe(*arguments):
            if arguments[-2:] == ("--find", "metal"):
                raise subprocess.CalledProcessError(1, arguments)
            return self.commands[arguments]

        self.probe.side_effect = probe
        with patch.object(identity, "toolchain_metadata", return_value={"swift": {}}):
            with self.assertRaises(subprocess.CalledProcessError):
                cache.toolchain_metadata("provider")
        self.assertEqual(dict(os.environ), {})

    def test_inconsistent_provider_overrides_are_rejected_without_mutation(self):
        for name, value in (("PROVIDER_SWIFT", "/other/swift"), ("PROVIDER_SDKROOT", "/other/sdk")):
            with self.subTest(name=name), patch.dict(os.environ, {name: value}, clear=True):
                with patch.object(identity, "toolchain_metadata") as metadata:
                    with self.assertRaisesRegex(ValueError, name + " differs"):
                        cache.toolchain_metadata("provider")
                    metadata.assert_not_called()
                self.assertEqual(dict(os.environ), {name: value})

    def test_usr_bin_shim_hashes_selected_compiler_and_retains_invocation(self):
        self.which.return_value = "/usr/bin/swift"

        def selected(lane):
            self.assertEqual(os.environ["PROVIDER_SWIFT"], "/Xcode/usr/bin/swift")
            return {"swift": {"binary": {"path": os.environ["PROVIDER_SWIFT"]}}}

        with patch.object(identity, "toolchain_metadata", side_effect=selected):
            for override in ("/usr/bin/swift", "/Xcode/usr/bin/swift"):
                with patch.dict(os.environ, {"PROVIDER_SWIFT": override}, clear=True):
                    metadata = cache.toolchain_metadata("provider")
                    self.assertEqual(metadata["swift"]["binary"]["path"], "/Xcode/usr/bin/swift")
                    self.assertEqual(metadata["swift"]["invocation"]["path"], "/usr/bin/swift")
                    self.assertEqual(dict(os.environ), {"PROVIDER_SWIFT": override})
            with patch.dict(os.environ, {"PROVIDER_SWIFT": "/different/swift"}, clear=True):
                with self.assertRaisesRegex(ValueError, "PROVIDER_SWIFT differs"):
                    cache.toolchain_metadata("provider")
        self.assertIn(("xcrun", "--sdk", "macosx", "--find", "swift"),
                      [call.args for call in self.probe.call_args_list])

    def test_missing_path_swift_fails_without_toolchain_probes(self):
        self.which.return_value = None
        with self.assertRaisesRegex(ValueError, "Swift is not executable on PATH"):
            cache.toolchain_metadata("provider")
        self.probe.assert_not_called()

    def test_delegated_probe_uses_pinned_rust_for_parity_and_integration(self):
        self.commands.update({
            ("xcrun", "--sdk", "/Xcode/SDKs/MacOSX.sdk", "--find", "clang"): "/Xcode/usr/bin/clang",
            ("/Xcode/usr/bin/clang", "--version"): "Apple clang version 18.0.0",
            ("/Xcode/usr/bin/swift", "--version"): "Apple Swift version 6.4",
            ("/Xcode/usr/bin/swift", "-print-target-info"): '{"target":{"triple":"arm64"}}',
            ("sw_vers", "-productVersion"): "26.2", ("sw_vers", "-buildVersion"): "25C100",
            ("xcodebuild", "-version"): "Xcode 27.0", ("xcode-select", "-p"): "/Xcode",
            ("rustc", "+1.88.0", "--print", "sysroot"): "/rust/1.88.0",
            ("rustc", "+1.88.0", "--version", "--verbose"): "rustc 1.88.0\ncommit-hash: abc",
            ("cargo", "+1.88.0", "--version"): "cargo 1.88.0",
        })
        with patch.object(identity, "external_file",
                          side_effect=lambda path: {"path": str(path), "sha256": "tool-bytes"}):
            for lane in cache.LANE_PURPOSES:
                self.probe.reset_mock()
                metadata = cache.toolchain_metadata(lane)
                rust_calls = [call.args for call in self.probe.call_args_list
                              if call.args[0] in {"rustc", "cargo"}]
                if lane in ("parity", "integration"):
                    self.assertIn("rust", metadata)
                    self.assertEqual(rust_calls, [("rustc", "+1.88.0", "--print", "sysroot"),
                                                  ("rustc", "+1.88.0", "--version", "--verbose"),
                                                  ("cargo", "+1.88.0", "--version")])
                else:
                    self.assertNotIn("rust", metadata)
                    self.assertEqual(rust_calls, [])
                self.assertEqual(dict(os.environ), {})
            self.which.return_value = "/usr/bin/swift"
            with patch.object(cache.Path, "is_file", return_value=True):
                metadata = cache.toolchain_metadata("provider")
            self.assertEqual(metadata["swift"]["binary"]["path"], "/Xcode/usr/bin/swift")
            self.assertEqual(metadata["swift"]["components"]["swift-frontend"]["path"],
                             "/Xcode/usr/bin/swift-frontend")
            self.assertEqual(metadata["swift"]["invocation"]["path"], "/usr/bin/swift")

    def test_failed_probes_restore_missing_and_empty_environment_values(self):
        os.environ["PROVIDER_SWIFT"] = ""
        for target in ("toolchain_metadata", "sdk_metadata"):
            with self.subTest(target=target):
                with patch.object(identity, "toolchain_metadata", return_value={"swift": {}}):
                    with patch.object(identity, target, side_effect=ValueError("probe failed")):
                        with self.assertRaisesRegex(ValueError, "probe failed"):
                            cache.toolchain_metadata("parity")
                self.assertEqual(dict(os.environ), {"PROVIDER_SWIFT": ""})


class CommandLineTests(unittest.TestCase):
    def test_scalar_output_cannot_inject_additional_github_records(self):
        outputs = {"swift-key": "key", "sdk-build": "build\r\nforged-key=evil",
                   "swift-version": "Swift\u2028another-key=bad\tversion"}
        stdout = io.StringIO()
        with patch.object(cache, "keys", return_value=outputs):
            with patch.object(cache.sys, "argv", [str(SCRIPT), "keys", "--lane", "provider"]):
                with redirect_stdout(stdout):
                    self.assertEqual(cache.main(), 0)
        self.assertEqual(stdout.getvalue().splitlines(),
                         ["swift-key=key", "sdk-build=build forged-key=evil",
                          "swift-version=Swift another-key=bad version"])

    def test_probe_errors_have_no_partial_output(self):
        stdout, stderr = io.StringIO(), io.StringIO()
        with patch.object(cache, "keys", side_effect=KeyError("PROVIDER_SWIFT")):
            with patch.object(cache.sys, "argv", [str(SCRIPT), "keys", "--lane", "parity"]):
                with redirect_stdout(stdout), redirect_stderr(stderr):
                    self.assertEqual(cache.main(), 1)
        self.assertEqual(stdout.getvalue(), "")
        self.assertIn("Provider CI cache:", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
