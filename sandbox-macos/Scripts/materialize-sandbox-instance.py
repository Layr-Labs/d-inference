#!/usr/bin/env python3
"""Create raw APFS images as the same unprivileged broker that prepared inputs."""

import argparse
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import stat
import subprocess
import sys
import tempfile
import re

sys.dont_write_bytecode = True

from sandbox_release_support import PACKAGE, require_encrypted_backing, run, sha256, write_json

spec = importlib.util.spec_from_file_location("instance_prepare", Path(__file__).resolve().with_name("prepare-sandbox-instance.py"))
instance_prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(instance_prepare)


def private_read(path: Path, owner: int) -> bytes:
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        metadata = os.fstat(descriptor)
        if (not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1
                or metadata.st_uid != owner or metadata.st_mode & 0o777 != 0o600
                or metadata.st_size > 16384):
            raise ValueError("unsafe private instance input")
        return os.read(descriptor, 16385)
    finally:
        os.close(descriptor)


def verify_raw_image(path: Path, expected_bytes: int):
    info = plistlib.loads(run(["/usr/bin/hdiutil", "imageinfo", "-plist", path],
                             capture_output=True).stdout)
    if info.get("Class Name") != "CRawDiskImage" or path.stat().st_size != expected_bytes:
        raise ValueError("image is not a raw disk of the expected byte size")
    if info.get("partitions", {}).get("partition-scheme") != "GUID":
        raise ValueError("raw image does not have the expected GUID partition map")


def verify_control_contents(image: Path, configuration: bytes, owner: int):
    mountpoint = image.parent / ".control-verification"
    mountpoint.mkdir(mode=0o700)
    result = run(["/usr/bin/hdiutil", "attach", "-readonly", "-owners", "on", "-nobrowse",
                  "-mountpoint", mountpoint, "-plist", image], capture_output=True)
    attachment = plistlib.loads(result.stdout)
    devices = [entry.get("dev-entry", "") for entry in attachment.get("system-entities", [])]
    whole = next((device for device in devices if re.fullmatch(r"/dev/disk[0-9]+", device)), None)
    if whole is None:
        raise ValueError("control image attachment lacks a whole device; retained for operator inspection")
    detached = False
    try:
        observed = private_read(mountpoint / "instance.json", owner)
        if observed != configuration:
            raise ValueError("control image did not preserve private instance configuration")
    finally:
        # Only this invocation's newly attached image is detached; never force or use a global target.
        run(["/usr/bin/hdiutil", "detach", whole], stdout=subprocess.DEVNULL)
        detached = True
        if detached:
            mountpoint.rmdir()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, required=True)
    args = parser.parse_args()
    if os.geteuid() in [0, 2001] or os.getegid() == 0:
        raise ValueError("materialization requires a non-root broker distinct from guest tenant UID2001")
    directory = args.directory.absolute()
    metadata = directory.lstat()
    if not stat.S_ISDIR(metadata.st_mode) or metadata.st_mode & 0o777 != 0o700:
        raise ValueError("instance directory must be a private real directory")
    owner = metadata.st_uid
    if owner != os.geteuid():
        raise ValueError("materialization must use the same broker identity that owns the directory")
    backing = require_encrypted_backing(directory)
    plan = json.loads((directory / "materialization-plan.json").read_bytes())
    configuration_bytes = private_read(directory / "instance.private.json", owner)
    configuration = json.loads(configuration_bytes)
    credential = instance_prepare.validate_configuration(configuration)
    if plan.get("schema_version") != 1 or plan.get("instanceID") != configuration["instanceID"]:
        raise ValueError("materialization plan and instance identity differ")
    if (plan.get("workspace_bytes") != configuration["workspaceDiskBytes"]
            or plan.get("control_bytes") != 128 * 1024 ** 2
            or plan.get("minimum_free_bytes") != 20 * 1024 ** 3
            or plan.get("broker_uid") != os.geteuid()
            or plan.get("broker_gid") != os.getegid()):
        raise ValueError("unsupported materialization policy")
    import base64
    if base64.b64decode(private_read(directory / "guest.credential", owner).strip(), validate=True) != credential:
        raise ValueError("broker credential and instance configuration differ")
    required = plan["workspace_bytes"] + plan["control_bytes"] + plan["minimum_free_bytes"]
    if shutil.disk_usage(directory).free < required:
        raise ValueError("insufficient disk capacity while preserving20GiB")
    control = directory / "control.cdr"
    workspace = directory / "workspace.cdr"
    for path in [control, workspace, directory / "material-manifest.json"]:
        if path.exists() or path.is_symlink():
            raise ValueError("existing material is retained; use a new instance directory")

    # No existing disk or mount is selected. hdiutil creates only these new image files.
    with tempfile.TemporaryDirectory(prefix=".broker-control-", dir=directory) as temporary:
        payload = Path(temporary) / "payload"
        payload.mkdir(mode=0o700)
        config_copy = payload / "instance.json"
        with config_copy.open("xb") as stream:
            stream.write(configuration_bytes)
        config_copy.chmod(0o600)
        run(["/usr/bin/hdiutil", "create", "-sectors", str(plan["control_bytes"] // 512),
             "-fs", "APFS", "-volname", "DBCONTROL", "-layout", "GPTSPUD",
             "-srcfolder", payload, "-srcowners", "on", "-anyowners", "-format", "UDTO", control])
        verify_raw_image(control, plan["control_bytes"])
        verify_control_contents(control, configuration_bytes, owner)
    run(["/usr/bin/hdiutil", "create", "-sectors", str(plan["workspace_bytes"] // 512),
         "-fs", "APFS", "-volname", "DBWORK", "-layout", "GPTSPUD", "-type", "UDTO", workspace])
    verify_raw_image(workspace, plan["workspace_bytes"])
    control.chmod(0o400)
    workspace.chmod(0o600)
    manifest = {"schema_version": 1, "instanceID": configuration["instanceID"],
                "image_encryption": "none", "backing_volume_encryption": backing,
                "guest_boot_validation": "not_performed",
                "controlPath": str(control), "controlBytes": control.stat().st_size,
                "workspacePath": str(workspace), "workspaceDiskBytes": workspace.stat().st_size,
                "images": [
                    {"role": "control", "path": str(control), "bytes": control.stat().st_size,
                     "sha256": sha256(control), "read_only": True},
                    {"role": "workspace", "path": str(workspace), "bytes": workspace.stat().st_size,
                     "sha256": sha256(workspace), "read_only": False},
                ]}
    write_json(directory / "material-manifest.json", manifest)
    (directory / "material-manifest.json").chmod(0o600)
    for path in [control, workspace, directory / "broker.json",
                 directory / "instance.private.json", directory / "material-manifest.json"]:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    descriptor = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    print(json.dumps(manifest))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f"instance materialization failed: {error}", file=sys.stderr)
        sys.exit(1)
