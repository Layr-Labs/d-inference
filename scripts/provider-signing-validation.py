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

TEAM = "SLDQ2GJ6TL"
APP_ID = "io.darkbloom.provider"
MAX_ARCHIVE_BYTES = 2 << 30
MAX_MEMBER_BYTES = 512 << 20
MAX_TOTAL_BYTES = 2 << 30
MAX_ARCHIVE_MEMBERS = 16_384


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
    app = root / "Darkbloom.app"
    binaries = app / "Contents/MacOS"
    helpers = app / "Contents/Helpers"
    resources = app / "Contents/Resources/darkbloom-runtime-capabilities"
    for path in [binaries, helpers, resources, root / "validation-inputs"]:
        path.mkdir(parents=True)
    for name in ["darkbloom", "darkbloom-enclave"]:
        shutil.copy2(arguments.bin / name, binaries / name)
    shutil.copy2(arguments.bin / "darkbloom-fan-helper", helpers / "darkbloom-fan-helper")
    shutil.copy2(arguments.metallib, binaries / "mlx.metallib")
    (resources / "fan-helper-v1").write_text("1\n")
    info = {
        "CFBundleIdentifier": APP_ID, "CFBundleExecutable": "darkbloom",
        "CFBundleName": "Darkbloom", "CFBundleVersion": arguments.version,
        "CFBundleShortVersionString": arguments.version,
        "CFBundlePackageType": "APPL", "LSMinimumSystemVersion": "14.0",
    }
    with (app / "Contents/Info.plist").open("wb") as output:
        plistlib.dump(info, output)
    for name in ["entitlements.plist", "entitlements-enclave.plist"]:
        shutil.copy2(arguments.source / "provider-swift" / name, root / "validation-inputs" / name)
    subprocess.run([
        "bash", str(Path(__file__).resolve().parent / "stage-swiftpm-resource-bundles.sh"),
        str(arguments.bin), str(app), str(root / "validation-inputs/resource-bundles.txt"),
    ], check=True)
    source_sha = subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=arguments.source, text=True).strip()
    submodules = subprocess.check_output(
        ["git", "submodule", "status", "--recursive"], cwd=arguments.source, text=True).splitlines()
    write_json(root / "unsigned-files.json", {
        "schema": 1, "source_sha": source_sha, "version": arguments.version,
        "submodules": submodules, "files": inventory(root),
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
    check_info(arguments.output, arguments.version)
    tooling = Path(__file__).resolve().parent.parent
    for name in ["entitlements.plist", "entitlements-enclave.plist"]:
        if sha256(arguments.output / "validation-inputs" / name) != sha256(tooling / "provider-swift" / name):
            raise ValueError("Candidate signing entitlements differ from reviewed workflow tooling")


def check_info(root, version):
    with (root / "Darkbloom.app/Contents/Info.plist").open("rb") as source:
        info = plistlib.load(source)
    required = {"CFBundleIdentifier": APP_ID, "CFBundleVersion": version,
                "CFBundleShortVersionString": version, "CFBundleExecutable": "darkbloom"}
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
    app_id = entitlements.get("application-identifier", "")
    if app_id and not (app_id.endswith(APP_ID) or app_id.endswith("*")):
        raise ValueError("Provisioning profile application identifier mismatch")
    expiration = value.get("ExpirationDate")
    if expiration is None or (expiration.replace(tzinfo=timezone.utc) - datetime.now(timezone.utc)).days < 30:
        raise ValueError("Provisioning profile expires in fewer than 30 days")


def receipt(arguments):
    root = arguments.output
    notarization = json.loads(arguments.notary.read_text())
    if notarization.get("status") != "Accepted" or not notarization.get("id"):
        raise ValueError("Notarization did not produce an accepted ticket")
    unsigned = json.loads((root / "unsigned-files.json").read_text())
    check_info(root, unsigned["version"])
    app = root / "Darkbloom.app"
    (root / "bin").mkdir()
    for name in ["darkbloom", "darkbloom-enclave", "mlx.metallib"]:
        shutil.copy2(app / "Contents/MacOS" / name, root / "bin" / name)
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
    unpack_parser = commands.add_parser("unpack")
    for name in ["archive", "output"]:
        unpack_parser.add_argument("--" + name, type=Path, required=True)
    unpack_parser.add_argument("--source-sha", required=True)
    unpack_parser.add_argument("--version", required=True)
    profile_parser = commands.add_parser("profile")
    profile_parser.add_argument("--profile", type=Path, required=True)
    entitlements_parser = commands.add_parser("cli-entitlements")
    entitlements_parser.add_argument("--plist", type=Path, required=True)
    receipt_parser = commands.add_parser("receipt")
    for name in ["output", "notary"]:
        receipt_parser.add_argument("--" + name, type=Path, required=True)
    arguments = parser.parse_args()
    {"stage": stage, "unpack": unpack, "profile": profile,
     "cli-entitlements": cli_entitlements, "receipt": receipt}[arguments.command](arguments)


if __name__ == "__main__":
    main()
