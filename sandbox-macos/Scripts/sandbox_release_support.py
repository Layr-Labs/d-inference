"""Small, dependency-free helpers for sandbox release preparation.

These tools prepare operator-reviewable artifacts. They never install services,
change host ownership, or infer physical isolation from a successful signature.
"""

from __future__ import annotations

import datetime as dt
import fnmatch
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess


PACKAGE = Path(__file__).resolve().parent.parent
TEAM = "SLDQ2GJ6TL"
HOST_ID = "io.darkbloom.sandbox"
GUEST_ID = "io.darkbloom.sandbox.guest"
KEYCHAIN_GROUP = TEAM + "." + HOST_ID
IDENTITY = "Developer ID Application: Eigen Labs, Inc. (SLDQ2GJ6TL)"


def require_encrypted_backing(path: Path) -> dict:
    before = path.stat()
    report = run(["/bin/df", "-P", path], capture_output=True, text=True).stdout.splitlines()
    if len(report) != 2:
        raise ValueError("cannot identify the instance backing filesystem")
    device = report[1].split()[0]
    if not re.fullmatch(r"/dev/disk[0-9]+(?:s[0-9]+)*", device):
        raise ValueError("instance backing storage must be a local APFS device")
    metadata = plistlib.loads(run(["/usr/sbin/diskutil", "info", "-plist", device],
                                 capture_output=True).stdout)
    after = path.stat()
    if (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino):
        raise ValueError("instance backing directory changed during inspection")
    if (metadata.get("FilesystemType") != "apfs" or metadata.get("FileVault") is not True
            or metadata.get("Encryption") is not True):
        raise ValueError("instance backing volume must have verified FileVault encryption")
    return {"scheme": "filevault", "device": device}


def run(arguments, **kwargs):
    return subprocess.run([str(x) for x in arguments], check=True, **kwargs)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_json(path: Path, value) -> None:
    with path.open("x", encoding="utf-8") as output:
        json.dump(value, output, indent=2, sort_keys=True)
        output.write("\n")


def new_directory(path: Path) -> Path:
    path = path.absolute()
    if path.exists() or path.is_symlink():
        raise ValueError(f"output already exists: {path}")
    if not path.parent.is_dir() or path.parent.is_symlink():
        raise ValueError("output parent must be an existing real directory")
    path.mkdir(mode=0o700)
    return path


def file_inventory(root: Path) -> dict[str, str]:
    """Reject links and special files; do not follow caller-controlled trees."""
    if not root.is_dir() or root.is_symlink():
        raise ValueError("release root must be a real directory")
    files = {}
    for parent, directories, names in os.walk(root, followlinks=False):
        for name in directories + names:
            path = Path(parent) / name
            metadata = path.lstat()
            if stat.S_ISDIR(metadata.st_mode):
                continue
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
                raise ValueError(f"release tree contains a link or special file: {path}")
            files[path.relative_to(root).as_posix()] = sha256(path)
    return dict(sorted(files.items()))


def validate_profile_data(profile: dict) -> dict:
    entitlements = profile.get("Entitlements", {})
    application = TEAM + "." + HOST_ID
    if entitlements.get("com.apple.application-identifier") != application:
        raise ValueError(f"profile must explicitly authorize {application}")
    if TEAM not in profile.get("TeamIdentifier", []):
        raise ValueError("profile belongs to a different team")
    if profile.get("ProvisionsAllDevices") is not True:
        raise ValueError("profile must be a Developer ID all-devices profile")
    if entitlements.get("get-task-allow", False):
        raise ValueError("debuggable provisioning profiles cannot sign a release")
    expiry = profile.get("ExpirationDate")
    if not isinstance(expiry, dt.datetime):
        raise ValueError("profile has no expiration")
    if expiry.replace(tzinfo=dt.timezone.utc) <= dt.datetime.now(dt.timezone.utc):
        raise ValueError("provisioning profile has expired")
    groups = entitlements.get("keychain-access-groups", [])
    if not any(fnmatch.fnmatchcase(KEYCHAIN_GROUP, group) for group in groups):
        raise ValueError("profile does not authorize the sandbox keychain group")
    return {
        "name": profile.get("Name"),
        "uuid": profile.get("UUID"),
        "expires": expiry.isoformat(),
        "application_identifier": application,
        "keychain_access_group": KEYCHAIN_GROUP,
    }


def read_profile(path: Path) -> tuple[dict, dict]:
    result = run(["/usr/bin/security", "cms", "-D", "-i", path], capture_output=True)
    profile = plistlib.loads(result.stdout)
    return profile, validate_profile_data(profile)


def sign(path: Path, identifier: str, identity: str, entitlements: Path | None = None):
    arguments = ["/usr/bin/codesign", "--force", "--sign", identity,
                 "--identifier", identifier]
    if identity != "-":
        arguments += ["--timestamp"]
        if path.suffix != ".json":
            arguments += ["--options", "runtime"]
    if entitlements:
        arguments += ["--entitlements", entitlements]
    run(arguments + [path])
    verify_signature(path, identifier, identity != "-")


def verify_signature(path: Path, identifier: str, production: bool):
    arguments = ["/usr/bin/codesign", "--verify", "--strict"]
    if production:
        requirement = (f'anchor apple generic and identifier "{identifier}" '
                       f'and certificate leaf[subject.OU] = "{TEAM}"')
        arguments += ["-R=" + requirement]
    run(arguments + [path])


def validate_lume(root: Path, production: bool) -> dict:
    if not root.is_dir() or root.is_symlink():
        raise ValueError("Lume runtime must be a real directory")
    lock = json.loads((PACKAGE / "ThirdParty/lume.lock.json").read_text())
    provenance_path = root / "lume.provenance.json"
    provenance = json.loads(provenance_path.read_text())
    expected = {
        "schema_version": 3,
        "repository": lock["repository"], "commit": lock["commit"],
        "source_path": lock["path"], "version": lock["version"],
        "patches": {p["path"]: p["sha256"] for p in lock["patches"]},
    }
    if any(provenance.get(key) != value for key, value in expected.items()):
        raise ValueError("Lume provenance does not match the repository lock")
    files = file_inventory(root)
    files.pop("lume.provenance.json", None)
    if files != provenance.get("files"):
        raise ValueError("Lume files differ from their signed provenance")
    directories = sorted(str(p.relative_to(root)) for p in root.rglob("*") if p.is_dir())
    if directories != sorted(provenance.get("directories", [])):
        raise ValueError("Lume directories differ from their signed provenance")
    for path in [root, *root.rglob("*")]:
        if path.lstat().st_mode & 0o222:
            raise ValueError(f"Lume runtime must be sealed against writes: {path}")
    verify_signature(root / "lume", HOST_ID + ".lume", production)
    verify_signature(provenance_path, HOST_ID + ".lume.provenance", production)
    return expected
