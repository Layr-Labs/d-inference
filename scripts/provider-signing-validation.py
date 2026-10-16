#!/usr/bin/env python3
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path, PurePosixPath
import plistlib
import shutil
import subprocess
import tarfile
import unicodedata

from provider_release_identity import DOCUMENT, for_source, identity

TEAM = "SLDQ2GJ6TL"
APP_ID = "io.darkbloom.provider"
MAX_ARCHIVE_BYTES = 2 << 30
MAX_MEMBER_BYTES = 512 << 20
MAX_TOTAL_BYTES = 2 << 30
MAX_ARCHIVE_MEMBERS = 16_384
# The cluster helpers the installed provider launches from
# Darkbloom.app/Contents/Helpers (the default worker path of a cluster setup),
# with the two files they load beside themselves.
CLUSTER_HELPER_EXECUTABLES = ("darkbloom-cluster-worker", "darkbloom-cluster-plan")
CLUSTER_HELPER_RESOURCES = ("mlx.metallib", "pagedattention.metal")
SIGNING_ENTITLEMENTS = ("entitlements.plist", "entitlements-enclave.plist", "entitlements-cluster-worker.plist")


PACKAGED_KEYS = ["cliName", "enclaveName", "appBundleName", "appDisplayName"]


def packaging(document, version):
    """Names the stage step packages, from the candidate's own identity. The
    unsigned manifest records them, so unpack and receipt use the same set."""
    names = identity(version, document)
    return {**{key: names[key] for key in PACKAGED_KEYS},
            "products": {"cli": document["swiftProducts"]["cli"],
                         "enclave": document["swiftProducts"]["enclave"]}}


def recorded_packaging(manifest):
    # An unsigned build staged before the manifest recorded names (a retained
    # build for recovery) packaged this tooling's names for its version.
    value = manifest.get("packaging", packaging(DOCUMENT, manifest.get("version", "")))
    names = [value.get(key) for key in PACKAGED_KEYS] if isinstance(value, dict) else [None]
    products = value.get("products") if isinstance(value, dict) else None
    if isinstance(products, dict):
        names += [products.get("cli"), products.get("enclave")]
    if not isinstance(products, dict) or not all(
            isinstance(name, str) and name and "/" not in name and name not in {".", ".."}
            and not name.startswith(".") for name in names):
        raise ValueError("Unsigned manifest has no valid packaged names")
    return value


def executables(packaged):
    """(SwiftPM product, packaged executable) pairs."""
    return [(packaged["products"]["cli"], packaged["cliName"]),
            (packaged["products"]["enclave"], packaged["enclaveName"])]


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def inventory(root):
    files = {}
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            raise ValueError(f"Unexpected package symlink: {path}")
        if path.is_file():
            files[str(path.relative_to(root))] = {
                "sha256": sha256(path), "bytes": path.stat().st_size,
            }
    return files


def write_json(path, value):
    with path.open("x") as destination:
        json.dump(value, destination, indent=2)
        destination.write("\n")


def stage(arguments):
    root = arguments.output
    root.mkdir(parents=True, exist_ok=False)
    names = packaging(for_source(arguments.source), arguments.version)
    app = root / names["appBundleName"]
    binaries = app / "Contents/MacOS"
    helpers = app / "Contents/Helpers"
    resources = app / "Contents/Resources/darkbloom-runtime-capabilities"
    for path in [binaries, helpers, resources, root / "validation-inputs"]:
        path.mkdir(parents=True)
    # The SwiftPM products keep their names; a dev release renames them here.
    for product, name in executables(names):
        shutil.copy2(arguments.bin / product, binaries / name)
    shutil.copy2(arguments.bin / "darkbloom-fan-helper", helpers / "darkbloom-fan-helper")
    shutil.copy2(arguments.metallib, binaries / "mlx.metallib")
    stage_cluster_helpers(arguments.cluster_helpers, helpers)
    (resources / "fan-helper-v1").write_text("1\n")
    info = {
        "CFBundleIdentifier": APP_ID, "CFBundleExecutable": names["cliName"],
        "CFBundleName": names["appDisplayName"], "CFBundleVersion": arguments.version,
        "CFBundleShortVersionString": arguments.version,
        "CFBundlePackageType": "APPL", "LSMinimumSystemVersion": "14.0",
        "NSLocalNetworkUsageDescription": "Darkbloom connects to the other Macs of your cluster over the "
                                          "Thunderbolt link to serve models together.",
    }
    with (app / "Contents/Info.plist").open("wb") as output:
        plistlib.dump(info, output)
    for name in SIGNING_ENTITLEMENTS:
        shutil.copy2(arguments.source / "provider-swift" / name, root / "validation-inputs" / name)
    subprocess.run([
        "bash", str(Path(__file__).resolve().parent / "stage-swiftpm-resource-bundles.sh"),
        str(arguments.bin), str(app), str(root / "validation-inputs/resource-bundles.txt"),
    ], check=True)
    check_cluster_helpers(app)
    source_sha = subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=arguments.source, text=True).strip()
    submodules = subprocess.check_output(
        ["git", "submodule", "status", "--recursive"], cwd=arguments.source, text=True).splitlines()
    write_json(root / "unsigned-files.json", {
        "schema": 1, "source_sha": source_sha, "version": arguments.version,
        "submodules": submodules, "packaging": names, "files": inventory(root),
    })


def unpack(arguments):
    if arguments.archive.stat().st_size > MAX_ARCHIVE_BYTES:
        raise ValueError("Archive size exceeds the validation limit")
    arguments.output.mkdir(parents=True, exist_ok=False)
    with tarfile.open(arguments.archive, "r:gz") as archive:
        members, names, total_bytes = [], set(), 0
        for member in archive:
            name = PurePosixPath(member.name)
            if name.is_absolute() or ".." in name.parts or not (member.isfile() or member.isdir()):
                raise ValueError(f"Unsafe package member: {member.name}")
            canonical = unicodedata.normalize("NFC", name.as_posix()).casefold()
            if canonical in names:
                raise ValueError(f"Duplicate package member: {member.name}")
            names.add(canonical)
            if member.size < 0 or member.size > MAX_MEMBER_BYTES:
                raise ValueError(f"Package member size exceeds the validation limit: {member.name}")
            total_bytes += member.size
            if total_bytes > MAX_TOTAL_BYTES:
                raise ValueError("Package total size exceeds the validation limit")
            if len(members) >= MAX_ARCHIVE_MEMBERS:
                raise ValueError("Package member count exceeds the validation limit")
            member.mode &= 0o777
            members.append(member)
        archive.extractall(arguments.output, members=members)
    manifest = json.loads((arguments.output / "unsigned-files.json").read_text())
    if manifest["source_sha"] != arguments.source_sha or manifest["version"] != arguments.version:
        raise ValueError("Unsigned artifact source/version differs from the dispatch inputs")
    actual = inventory(arguments.output)
    actual.pop("unsigned-files.json")
    if actual != manifest["files"]:
        raise ValueError("Unsigned artifact inventory changed")
    names = recorded_packaging(manifest)
    check_info(arguments.output, arguments.version, names)
    check_cluster_helpers(arguments.output / names["appBundleName"])
    tooling = Path(__file__).resolve().parent.parent
    for name in SIGNING_ENTITLEMENTS:
        if sha256(arguments.output / "validation-inputs" / name) != sha256(tooling / "provider-swift" / name):
            raise ValueError("Candidate signing entitlements differ from reviewed workflow tooling")


def stage_cluster_helpers(source, helpers):
    """Copies the built cluster helpers (scripts/build-cluster-helpers.sh) into Contents/Helpers."""
    if source is None or not source.is_dir() or source.is_symlink():
        raise ValueError("Cluster helpers directory is missing: build it with scripts/build-cluster-helpers.sh")
    for name in CLUSTER_HELPER_EXECUTABLES + CLUSTER_HELPER_RESOURCES:
        path = source / name
        if path.is_symlink() or not path.is_file():
            raise ValueError(f"Cluster helper is missing from the build: {name}")
        destination = helpers / name
        shutil.copyfile(path, destination)
        destination.chmod(0o755 if name in CLUSTER_HELPER_EXECUTABLES else 0o644)


def is_arm64_macho(path):
    with path.open("rb") as source:
        header = source.read(8)
    # MH_MAGIC_64 (little-endian) and CPU_TYPE_ARM64.
    return len(header) == 8 and header[:4] == bytes.fromhex("cffaedfe") and header[4:8] == bytes.fromhex("0c000001")


def check_cluster_helpers(app):
    """Fails unless Darkbloom.app carries both cluster helpers where the installed
    provider looks for them, with the Metal library and paged-attention source
    they load beside themselves, byte-identical to the app's own copies."""
    helpers = app / "Contents/Helpers"
    for name in CLUSTER_HELPER_EXECUTABLES + CLUSTER_HELPER_RESOURCES:
        path = helpers / name
        if path.is_symlink() or not path.is_file() or path.stat().st_size == 0:
            raise ValueError(f"Darkbloom.app/Contents/Helpers/{name} is missing: the release must ship the cluster helpers")
    for name in CLUSTER_HELPER_EXECUTABLES:
        path = helpers / name
        if not is_arm64_macho(path):
            raise ValueError(f"Darkbloom.app/Contents/Helpers/{name} is not an arm64 Mach-O executable")
        if path.stat().st_mode & 0o111 != 0o111:
            raise ValueError(f"Darkbloom.app/Contents/Helpers/{name} is not executable")
    main_metallib = app / "Contents/MacOS/mlx.metallib"
    if not main_metallib.is_file() or sha256(main_metallib) != sha256(helpers / "mlx.metallib"):
        raise ValueError("The cluster helpers' mlx.metallib differs from Contents/MacOS/mlx.metallib")
    paged = [path for path in sorted((app / "Contents/Resources").glob("*.bundle/pagedattention.metal")) if path.is_file()]
    if len(paged) != 1 or sha256(paged[0]) != sha256(helpers / "pagedattention.metal"):
        raise ValueError("The cluster helpers' pagedattention.metal differs from the app's resource bundle copy")


def cluster_helpers(arguments):
    check_cluster_helpers(arguments.app)


def check_info(root, version, names):
    path = root / names["appBundleName"] / "Contents/Info.plist"
    if not path.is_file():
        raise ValueError(f"Artifact has no {names['appBundleName']} for version {version}")
    with path.open("rb") as source:
        info = plistlib.load(source)
    required = {"CFBundleIdentifier": APP_ID, "CFBundleVersion": version,
                "CFBundleShortVersionString": version, "CFBundleExecutable": names["cliName"],
                "CFBundleName": names["appDisplayName"]}
    if not isinstance(info, dict) or any(info.get(key) != value for key, value in required.items()):
        raise ValueError("App Info.plist identity/version does not match the expected source")


def cli_entitlements(arguments):
    with arguments.plist.open("rb") as source:
        value = plistlib.load(source)
    if not isinstance(value, dict):
        raise ValueError("Signed CLI entitlements are not a dictionary")
    groups = value.get("keychain-access-groups", [])
    if not isinstance(groups, list) or TEAM + "." + APP_ID not in groups:
        raise ValueError("Signed CLI lacks the required keychain access group")
    if value.get("com.apple.developer.aps-environment") != "production":
        raise ValueError("Signed CLI lacks the required APNs entitlement")
    for key in ["get-task-allow", "com.apple.security.get-task-allow"]:
        if value.get(key, False) is not False:
            raise ValueError("Signed CLI enables or malforms get-task-allow")


def profile(arguments):
    with arguments.profile.open("rb") as source:
        value = plistlib.load(source)
    entitlements = value.get("Entitlements", {})
    groups = entitlements.get("keychain-access-groups", [])
    if TEAM not in value.get("TeamIdentifier", []):
        raise ValueError("Provisioning profile team mismatch")
    if TEAM + "." + APP_ID not in groups and TEAM + ".*" not in groups:
        raise ValueError("Provisioning profile does not authorize the provider access group")
    if entitlements.get("aps-environment", entitlements.get("com.apple.developer.aps-environment")) != "production":
        raise ValueError("Provisioning profile lacks the required APNs entitlement")
    expected_app_id = TEAM + "." + APP_ID
    # macOS uses the long key; other profiles may use the short spelling.
    # Developer ID profiles may omit it, but every declared value must cover
    # this exact team/app. A wildcard grants only its own prefix, not any app.
    for key in ["com.apple.application-identifier", "application-identifier"]:
        if key not in entitlements:
            continue
        app_id = entitlements[key]
        if not isinstance(app_id, str) or not (app_id == expected_app_id or (
                app_id.startswith(TEAM + ".") and app_id.endswith("*")
                and app_id.count("*") == 1 and expected_app_id.startswith(app_id[:-1]))):
            raise ValueError("Provisioning profile application identifier mismatch: " + key)
    expiration = value.get("ExpirationDate")
    if expiration is None or (expiration.replace(tzinfo=timezone.utc) - datetime.now(timezone.utc)).days < 30:
        raise ValueError("Provisioning profile expires in fewer than 30 days")


def receipt(arguments):
    root = arguments.output
    notarization = json.loads(arguments.notary.read_text())
    if notarization.get("status") != "Accepted" or not notarization.get("id"):
        raise ValueError("Notarization did not produce an accepted ticket")
    unsigned = json.loads((root / "unsigned-files.json").read_text())
    names = recorded_packaging(unsigned)
    check_info(root, unsigned["version"], names)
    app = root / names["appBundleName"]
    check_cluster_helpers(app)
    (root / "bin").mkdir()
    # The flat verifier copies keep the product names for both identities.
    for product, name in executables(names):
        shutil.copy2(app / "Contents/MacOS" / name, root / "bin" / product)
    shutil.copy2(app / "Contents/MacOS/mlx.metallib", root / "bin/mlx.metallib")
    write_json(root / "signing-validation.json", {
        "schema": 1, "scope": "signing_and_notarization_validation_only",
        "source_sha": unsigned["source_sha"], "version": unsigned["version"],
        "submodules": unsigned["submodules"], "notarization_id": notarization["id"],
        "notarization_status": notarization["status"], "files": inventory(root),
        "model_execution": False, "runtime_smoke": False, "release_published": False,
    })


def main():
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    stage_parser = commands.add_parser("stage")
    for name in ["source", "bin", "metallib", "output"]:
        stage_parser.add_argument("--" + name, type=Path, required=True)
    stage_parser.add_argument("--version", required=True)
    stage_parser.add_argument("--cluster-helpers", type=Path, required=True,
                              help="Output of scripts/build-cluster-helpers.sh")
    unpack_parser = commands.add_parser("unpack")
    for name in ["archive", "output"]:
        unpack_parser.add_argument("--" + name, type=Path, required=True)
    unpack_parser.add_argument("--source-sha", required=True)
    unpack_parser.add_argument("--version", required=True)
    profile_parser = commands.add_parser("profile")
    profile_parser.add_argument("--profile", type=Path, required=True)
    entitlements_parser = commands.add_parser("cli-entitlements")
    entitlements_parser.add_argument("--plist", type=Path, required=True)
    helpers_parser = commands.add_parser("cluster-helpers")
    helpers_parser.add_argument("--app", type=Path, required=True)
    receipt_parser = commands.add_parser("receipt")
    for name in ["output", "notary"]:
        receipt_parser.add_argument("--" + name, type=Path, required=True)
    arguments = parser.parse_args()
    {"stage": stage, "unpack": unpack, "profile": profile,
     "cli-entitlements": cli_entitlements, "cluster-helpers": cluster_helpers, "receipt": receipt}[arguments.command](arguments)


if __name__ == "__main__":
    main()
