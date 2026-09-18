"""Hash the actual compiler/SDK, dependency pins, paths, and build recipe."""

import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import plistlib
import subprocess

from .tracked import file_hash, git, inventory


CACHE_VERSION = "v1"
RUST_VERSION = "1.88.0"
RECIPE_PATHS = (
    ".github/actions/provider-release-build/action.yml",
    "scripts/provider-release-cache.py",
    "scripts/provider-release-swift.sh",
    "scripts/prepare-provider-release-toolchain.sh",
    "scripts/prepare-metal-toolchain.py",
    "scripts/run-provider-tests.sh",
    "scripts/run-provider-test-watchdog.py",
    "scripts/verify-prompt-parity.sh",
    "scripts/fetch-metallib.sh",
)
# Only build inputs, never arbitrary environment variables or credentials.
BUILD_ENV = (
    "MACOSX_DEPLOYMENT_TARGET", "MLX_METALLIB_DEPLOYMENT_TARGET",
    "CFLAGS", "CXXFLAGS", "CPPFLAGS", "LDFLAGS", "RUSTFLAGS",
    "CARGO_ENCODED_RUSTFLAGS", "CARGO_BUILD_TARGET", "CC", "CXX",
)


def digest(value: object) -> str:
    payload = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(payload).hexdigest()


def command(*arguments: str) -> str:
    return subprocess.check_output(arguments, text=True).strip()


def external_file(path: Path) -> dict:
    """Hash selected tool bytes as well as both invocation and resolved paths."""
    resolved = path.resolve(strict=True)
    sha = hashlib.sha256()
    with resolved.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            sha.update(chunk)
    return {"path": str(path.absolute()), "resolved": str(resolved), "sha256": sha.hexdigest()}


def sdk_metadata(sdk: Path) -> dict:
    """Read the selected SDK directly; xcrun can reject valid CLT SDK paths."""
    settings = json.loads((sdk / "SDKSettings.json").read_text())
    sdk_files = {"SDKSettings.json": external_file(sdk / "SDKSettings.json")}
    documents = {"SDKSettings.json": settings}
    for relative in ("SDKSettings.plist", "System/Library/CoreServices/SystemVersion.plist"):
        if (sdk / relative).is_file():
            sdk_files[relative] = external_file(sdk / relative)
            documents[relative] = plistlib.loads((sdk / relative).read_bytes())
    build = None
    build_source = "metadata-content-digest"
    for relative in ("System/Library/CoreServices/SystemVersion.plist",
                     "SDKSettings.json", "SDKSettings.plist"):
        candidate = documents.get(relative, {}).get("ProductBuildVersion")
        if isinstance(candidate, str) and candidate.strip():
            build = candidate.strip()
            build_source = relative + ":ProductBuildVersion"
            break
    if build is None:
        # Some SDK distributions omit Apple's build label. Keep a distinct,
        # explicitly content-derived identity, never substitute the default SDK.
        build = "metadata-sha256:" + digest({name: info["sha256"]
                                             for name, info in sdk_files.items()})
    return {
        "version": settings["Version"], "build": build, "build_source": build_source,
        "path": str(sdk.absolute()), "resolved": str(sdk.resolve(strict=True)),
        "files": sdk_files,
    }


def toolchain_metadata(lane: str) -> dict:
    swift = Path(os.environ["PROVIDER_SWIFT"])
    sdk = Path(os.environ["PROVIDER_SDKROOT"])
    clang = Path(command("xcrun", "--sdk", str(sdk), "--find", "clang"))
    result = {
        "os": platform.system(),
        "arch": platform.machine(),
        "os_version": command("sw_vers", "-productVersion"),
        "os_build": command("sw_vers", "-buildVersion"),
        "swift": {
            "version": command(str(swift), "--version"),
            "binary": external_file(swift),
            # swift is commonly a driver symlink; compiler payload changes
            # must invalidate objects even if a version label is reused.
            "components": {
                name: external_file(swift.parent / name)
                if (swift.parent / name).is_file() else "absent"
                for name in ("swift-frontend", "swiftc", "clang")
            },
            "target": json.loads(command(str(swift), "-print-target-info")),
        },
        "sdk": sdk_metadata(sdk),
        "xcode": {
            "version": command("xcodebuild", "-version"),
            "developer_dir": os.environ.get("DEVELOPER_DIR") or command("xcode-select", "-p"),
            "clang": external_file(clang),
            "clang_version": command(str(clang), "--version"),
        },
        "build_env": {name: os.environ.get(name, "") for name in BUILD_ENV},
    }
    if lane == "qualification":
        rust_sysroot = Path(command("rustc", f"+{RUST_VERSION}", "--print", "sysroot"))
        result["rust"] = {
            "version": command("rustc", f"+{RUST_VERSION}", "--version", "--verbose"),
            "cargo_version": command("cargo", f"+{RUST_VERSION}", "--version"),
            "compiler": external_file(rust_sysroot / "bin/rustc"),
            "cargo": external_file(rust_sysroot / "bin/cargo"),
        }
    return result


def dependency_file(path: str) -> bool:
    name = PurePosixPath(path).name
    return name in {"Package.swift", "Package.resolved", "Cargo.toml", "Cargo.lock",
                    "rust-toolchain", "rust-toolchain.toml", ".gitmodules"} or (
        ".cargo" in PurePosixPath(path).parts and name in {"config", "config.toml"}
    )


def keys(root: Path, lane: str, metadata: dict | None = None) -> dict[str, str]:
    if lane not in {"release", "qualification"}:
        raise ValueError("Unknown provider build lane")
    checkout_path = str(root.absolute())
    root = root.resolve(strict=True)
    tracked = inventory(root)
    metadata = metadata if metadata is not None else toolchain_metadata(lane)
    dependencies = {
        "files": {path: file_hash(root, path) for path in sorted(tracked.files)
                  if dependency_file(path)},
        "gitlinks": tracked.gitlinks,
    }
    recipe_paths = set(RECIPE_PATHS)
    recipe_paths.update(
        path.relative_to(root).as_posix()
        for path in (root / "scripts/provider_release_cache").glob("*.py")
    )
    recipe = {path: file_hash(root, path) if (root / path).exists() else "absent"
              for path in sorted(recipe_paths)}
    compatibility = {
        "version": CACHE_VERSION, "lane": lane,
        "checkout": checkout_path, "resolved_checkout": str(root),
        "toolchain": metadata, "dependencies": dependencies, "recipe": recipe,
    }
    compatibility_hash = digest(compatibility)
    commit = git(root, "rev-parse", "HEAD").decode("ascii").strip()
    # The sole restore prefix retains *all* compatibility boundaries. Only
    # source generation varies, allowing unchanged objects to remain reusable.
    result = {}
    for kind in (("swift", "rust") if lane == "qualification" else ("swift",)):
        prefix = f"provider-{kind}-{CACHE_VERSION}-{lane}-{compatibility_hash}-"
        result[f"{kind}-prefix"] = prefix
        result[f"{kind}-key"] = prefix + commit
    result.update({
        "toolchain-digest": digest(metadata),
        "dependency-digest": digest(dependencies),
        "recipe-digest": digest(recipe),
        "swift-version": metadata["swift"]["version"].splitlines()[0],
        "sdk-version": metadata["sdk"]["version"],
        "sdk-build": metadata["sdk"]["build"],
    })
    if lane == "qualification":
        result["rust-version"] = metadata["rust"]["version"].splitlines()[0]
    return result
