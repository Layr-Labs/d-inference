#!/usr/bin/env python3
"""Emit compatible cache keys for provider, nested SDK, and prompt parity CI.

Run `keys --lane provider|sdk|parity` after checkout and Metal toolchain setup.
Parity requires Rust 1.88.0 to be installed first. Redirect scalar stdout to
GITHUB_OUTPUT. Swift/Rust restore prefixes retain all compatibility boundaries;
the shared metallib key is exact-only. Cache hits never authorize skipping tests
or the source-matched metallib verification/staging helpers.
"""

import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys

from provider_release_cache import identity, tracked


CACHE_VERSION = "v1"
LANE_PURPOSES = {
    "provider": "provider-debug-tests",
    "sdk": "sdk-nested-debug-tests",
    "parity": "parity-swift-debug-rust",
}
MLX_SOURCE = "libs/mlx-swift/Source/Cmlx/mlx"
METALLIB_RECIPE_PATHS = ("scripts/fetch-metallib.sh", "scripts/stage-test-metallib.sh")
RECIPE_PATHS = (
    ".github/workflows/ci.yml",
    ".github/actions/provider-ci-build/action.yml",
    "scripts/provider-ci-cache.py",
    "scripts/test-provider-ci-cache.py",
    "scripts/provider-release-cache.py",
    "scripts/prepare-metal-toolchain.py",
    "scripts/run-provider-tests.sh",
    "scripts/run-provider-test-watchdog.py",
    "scripts/run-nested-suite.sh",
    "scripts/run-paged-kernel-tests.sh",
    "scripts/verify-prompt-parity.sh",
    *METALLIB_RECIPE_PATHS,
)


def toolchain_metadata(lane: str) -> dict:
    """Fingerprint bare PATH Swift builds without changing their environment."""
    if lane not in LANE_PURPOSES:
        raise ValueError("Unknown provider CI lane")
    swift_path = shutil.which("swift")
    if swift_path is None:
        raise ValueError("Swift is not executable on PATH")
    invocation = Path(swift_path).absolute()
    # Apple's /usr/bin driver delegates to the selected Xcode toolchain;
    # fingerprint that compiler's siblings, not unrelated /usr/bin tools.
    compiler = invocation
    if invocation.resolve() == Path("/usr/bin/swift"):
        compiler = Path(identity.command("xcrun", "--sdk", "macosx", "--find", "swift"))
    metal_sdk = Path(identity.command("xcrun", "--sdk", "macosx", "--show-sdk-path"))
    sdk = Path(os.environ.get("SDKROOT") or str(metal_sdk))
    swift_override = os.environ.get("PROVIDER_SWIFT")
    sdk_override = os.environ.get("PROVIDER_SDKROOT")
    if swift_override and Path(swift_override).resolve() not in {invocation.resolve(), compiler.resolve()}:
        raise ValueError("PROVIDER_SWIFT differs from the compiler invoked by PATH swift")
    if sdk_override and Path(sdk_override).resolve() != sdk.resolve():
        raise ValueError("PROVIDER_SDKROOT differs from the effective SDKROOT")
    selected = {"PROVIDER_SWIFT": str(compiler), "PROVIDER_SDKROOT": str(sdk)}
    previous = {name: os.environ.get(name) for name in selected}
    try:
        os.environ.update(selected)
        metadata = identity.toolchain_metadata("qualification" if lane == "parity" else "release")
        metadata["swift"]["invocation"] = identity.external_file(invocation)
        # fetch-metallib.sh uses xcrun's macosx SDK, which can differ from an
        # explicit SDKROOT used by the Swift build.
        metadata["metallib_sdk"] = identity.sdk_metadata(metal_sdk)
        metal = Path(identity.command("xcrun", "--no-cache", "--sdk", "macosx", "--find", "metal"))
        # Downloaded Metal components can mount at different paths on each
        # runner. Their version and bytes, not mount location, identify codegen.
        metadata["metal"] = {
            "version": identity.command("xcrun", "--no-cache", "--sdk", "macosx", "metal", "--version"),
            "compiler": {"sha256": identity.external_file(metal)["sha256"]},
        }
        return metadata
    finally:
        for name, value in previous.items():
            if value is None:
                os.environ.pop(name, None)
            else:
                os.environ[name] = value


def keys(root: Path, lane: str, metadata: dict | None = None) -> dict[str, str]:
    if lane not in LANE_PURPOSES:
        raise ValueError("Unknown provider CI lane")
    checkout_path = str(root.absolute())
    root = root.resolve(strict=True)
    sources = tracked.inventory(root)
    metadata = metadata if metadata is not None else toolchain_metadata(lane)
    if lane != "parity":
        metadata = {name: value for name, value in metadata.items() if name != "rust"}
    dependencies = {
        "files": {path: tracked.file_hash(root, path) for path in sorted(sources.files)
                  if identity.dependency_file(path)},
        "gitlinks": sources.gitlinks,
    }
    recipe_paths = set(RECIPE_PATHS)
    recipe_paths.update(path.relative_to(root).as_posix()
                        for path in (root / "scripts/provider_release_cache").glob("*.py"))
    recipe = {path: tracked.file_hash(root, path) if (root / path).exists() else "absent"
              for path in sorted(recipe_paths)}
    compatibility_hash = identity.digest({
        "version": CACHE_VERSION, "purpose": LANE_PURPOSES[lane],
        "checkout": checkout_path, "resolved_checkout": str(root),
        "toolchain": metadata, "dependencies": dependencies, "recipe": recipe,
    })
    commit = tracked.git(root, "rev-parse", "HEAD").decode("ascii").strip()
    result = {}
    for kind in (("swift", "rust") if lane == "parity" else ("swift",)):
        prefix = f"provider-ci-{kind}-{CACHE_VERSION}-{LANE_PURPOSES[lane]}-{compatibility_hash}-"
        result[f"{kind}-prefix"] = prefix
        result[f"{kind}-key"] = prefix + commit

    mlx_commit = sources.gitlinks.get(MLX_SOURCE)
    if mlx_commit is None:
        raise ValueError(f"Native MLX source is not an initialized gitlink: {MLX_SOURCE}")
    deployment_target = metadata["build_env"].get("MLX_METALLIB_DEPLOYMENT_TARGET") or "26.2"
    metallib_hash = identity.digest({
        "version": CACHE_VERSION, "mlx_commit": mlx_commit,
        "xcode": metadata["xcode"], "sdk": metadata["metallib_sdk"], "metal": metadata["metal"],
        "os": metadata["os"], "arch": metadata["arch"],
        "os_version": metadata["os_version"], "os_build": metadata["os_build"],
        "deployment_target": deployment_target, "jit": "OFF",
        "build_env": {name: metadata["build_env"].get(name, "")
                      for name in ("CFLAGS", "CXXFLAGS", "CPPFLAGS", "LDFLAGS", "CC", "CXX")},
        "recipe": {path: recipe[path] for path in METALLIB_RECIPE_PATHS},
    })
    result.update({
        "metallib-key": f"provider-ci-metallib-{CACHE_VERSION}-{mlx_commit}-{metallib_hash}",
        "mlx-sha": mlx_commit, "mlx-sha-short": mlx_commit[:12],
        "metallib-deployment-target": deployment_target,
        "toolchain-digest": identity.digest(metadata),
        "dependency-digest": identity.digest(dependencies),
        "recipe-digest": identity.digest(recipe),
        "swift-version": metadata["swift"]["version"].splitlines()[0],
        "sdk-version": metadata["sdk"]["version"], "sdk-build": metadata["sdk"]["build"],
    })
    if lane == "parity":
        result["rust-version"] = metadata["rust"]["version"].splitlines()[0]
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subcommands = parser.add_subparsers(dest="command", required=True)
    command = subcommands.add_parser("keys")
    command.add_argument("--root", type=Path, default=Path.cwd())
    command.add_argument("--lane", choices=tuple(LANE_PURPOSES), required=True)
    args = parser.parse_args()
    try:
        for name, value in keys(args.root, args.lane).items():
            # Version labels are public but untrusted scalar values, not records.
            value = " ".join(str(value).split())
            print(f"{name}={value}")
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(f"Provider CI cache: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
