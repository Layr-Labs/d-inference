#!/usr/bin/env python3
"""Prepare launchd configuration and a reviewable host installation plan.

No account, ownership, process, VM, or service mutations are performed.
"""

import argparse
import ipaddress
import json
from pathlib import Path
import re
import sys
import urllib.parse
import uuid

from sandbox_release_support import (
    HOST_ID, file_inventory, validate_lume, verify_signature,
)
from sandbox_gui_host_plan import generate_gui_plan, installed_identity_path
from sandbox_gui_install_validation import validate_gui_installation
from sandbox_gui_user_identity import validate_gui_user



def validate_package(path: Path):
    manifest_path = path / "release-manifest.json"
    manifest = json.loads(manifest_path.read_text())
    if manifest.get("schema_version") != 1 or manifest.get("signing_mode") != "developer_id":
        raise ValueError("host installation requires a Developer ID release package")
    verify_signature(manifest_path, HOST_ID + ".release-manifest", True)
    if not manifest.get("provisioning"):
        raise ValueError("host installation requires the sandbox-specific provisioning profile")
    files = file_inventory(path)
    files.pop("release-manifest.json", None)
    if files != manifest.get("files"):
        raise ValueError("release package differs from its signed manifest")
    verify_signature(path / "DarkbloomSandbox.app", HOST_ID, True)
    verify_signature(path / "guest/darkbloom-sandbox-guest", HOST_ID + ".guest", True)
    validate_lume(path / "lume", True)
    return manifest


def validate_coordinator_url(value):
    message = "coordinatorURL must be WSS with a valid host/port and exact /ws/sandbox-host path, without credentials, query or fragment"
    if not isinstance(value, str) or any(c.isspace() or ord(c) < 32 or ord(c) == 127 for c in value):
        raise ValueError(message)
    try:
        coordinator = urllib.parse.urlsplit(value)
        host, port = coordinator.hostname, coordinator.port
        if coordinator.scheme != "wss" or not host or coordinator.path != "/ws/sandbox-host" \
                or coordinator.username is not None or coordinator.password is not None \
                or "?" in value or "#" in value or coordinator.netloc.endswith(":") \
                or port is not None and not 1 <= port <= 65535:
            raise ValueError(message)
        if ":" in host:
            if not re.fullmatch(r"\[[0-9A-Fa-f:.]+\](?::[0-9]+)?", coordinator.netloc):
                raise ValueError(message)
            ipaddress.IPv6Address(host)
        else:
            try:
                ipaddress.IPv4Address(host)
            except ipaddress.AddressValueError:
                if all(c in "0123456789." for c in host):
                    raise ValueError(message)
                encoded = host.encode("idna").decode("ascii").removesuffix(".")
                labels = encoded.split(".")
                if len(encoded) > 253 or any(not re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?", label) for label in labels):
                    raise ValueError(message)
    except (ValueError, UnicodeError):
        raise ValueError(message) from None


def host_arguments(configuration: dict, install_root: Path):
    validate_coordinator_url(configuration["coordinatorURL"])
    host_id = str(uuid.UUID(configuration["hostID"]))
    paths = {}
    for key in ["tokenFile", "storageDirectory", "capacityDirectory"]:
        path = Path(configuration[key])
        if not path.is_absolute() or ".." in path.parts or path.is_symlink():
            raise ValueError(f"{key} must be an absolute path without traversal or symlinks")
        paths[key] = str(path)
    if len(set(paths.values())) != 3:
        raise ValueError("token, storage and capacity paths must differ")
    limits = {}
    for key in ["maximumCPUCount", "maximumMemoryGiB", "maximumGrowthGiB", "storageHeadroomGiB"]:
        value = configuration[key]
        if type(value) is not int or not 0 < value <= 65535:
            raise ValueError(f"{key} must be a positive integer below 65536")
        limits[key] = str(value)
    images = configuration["baseImageIDs"]
    if not isinstance(images, list) or not images or any(
        not isinstance(image, str) or not image or "," in image or any(c.isspace() for c in image)
        for image in images
    ):
        raise ValueError("baseImageIDs must be a nonempty list of image identifiers")
    return [str(install_root / "DarkbloomSandbox.app/Contents/MacOS/darkbloom-sandboxd"),
            "serve", "--host-identity-file", str(installed_identity_path(configuration)), "--coordinator", configuration["coordinatorURL"], "--host-id", host_id,
            "--guest-release", str(install_root),
            "--token-file", paths["tokenFile"], "--lume", str(install_root / "lume/lume"),
            "--storage", paths["storageDirectory"], "--capacity-dir", paths["capacityDirectory"],
            "--base-images", ",".join(images), "--max-cpu", limits["maximumCPUCount"],
            "--max-memory-gib", limits["maximumMemoryGiB"], "--max-growth-gib", limits["maximumGrowthGiB"],
            "--storage-headroom-gib", limits["storageHeadroomGiB"]]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package", type=Path, required=True)
    parser.add_argument("--configuration", type=Path, required=True, help="non-secret host settings JSON")
    parser.add_argument("--install-root", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--verify-installed", action="store_true")
    parser.add_argument("--gui-user-plan", action="store_true",
                        help="prepare or validate the explicit selected GUI-user qualification plan")
    args = parser.parse_args()
    if not args.gui_user_plan:
        raise ValueError("nonlogin LaunchDaemon deployment is unsupported; select --gui-user-plan with an explicit hostUser")
    if not args.install_root.is_absolute() or ".." in args.install_root.parts:
        parser.error("--install-root must be absolute and contain no traversal")
    configuration = json.loads(args.configuration.read_text())
    arguments = host_arguments(configuration, args.install_root)
    user, observations = validate_gui_user(configuration.get("hostUser"),
                                           require_runtime_membership=args.verify_installed)
    manifest = validate_package(args.package)
    if args.verify_installed:
        if validate_package(args.install_root) != manifest:
            raise ValueError("installed release differs from the selected signed package")
        report = validate_gui_installation(configuration, arguments, args.install_root, user, observations)
    else:
        if not args.output:
            parser.error("preparation requires --output")
        report = generate_gui_plan(configuration, arguments, user, observations, manifest,
                                   args.package, args.install_root, args.output)
    print(json.dumps(report))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError) as error:
        print(f"host preparation failed: {error}", file=sys.stderr)
        sys.exit(1)
