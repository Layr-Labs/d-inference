"""Reuse a manifest-verified guest without changing its signed identity."""

import json
import os
from pathlib import Path
import stat

from sandbox_install_validation import require_no_extended_acl
from sandbox_release_support import GUEST_ID, HOST_ID, file_inventory, run, sha256, verify_signature

GUEST_FILES = ("darkbloom-sandbox-guest", "darkbloom-sandbox-bootstrap.sh",
               "io.darkbloom.sandbox.guest.plist", "install-sandbox-guest.sh")


def _safe_entry(path, directory=False, ancestor=False):
    metadata = path.lstat()
    expected = stat.S_ISDIR if directory else stat.S_ISREG
    temporary_ancestor = ancestor and metadata.st_uid == 0 and metadata.st_mode & stat.S_ISVTX
    if not expected(metadata.st_mode) or metadata.st_uid not in (0, os.geteuid()) \
            or metadata.st_mode & 0o022 and not temporary_ancestor \
            or not directory and (metadata.st_nlink != 1 or metadata.st_size > 128 * 1024 * 1024):
        raise ValueError(f"unsafe guest release metadata: {path}")
    require_no_extended_acl(path)


def _canonical(path):
    absolute = Path(os.path.abspath(path))
    resolved = absolute.resolve(strict=True)
    aliases = [absolute]
    for name in ("tmp", "var"):
        prefix = Path("/" + name)
        if absolute == prefix or prefix in absolute.parents:
            aliases.append(Path("/private") / absolute.relative_to("/"))
    if resolved not in aliases:
        raise ValueError("guest release path contains an unsupported symlink")
    return resolved


def validate_guest_release(path):
    root = _canonical(path)
    for ancestor in reversed(root.parents):
        _safe_entry(ancestor, directory=True, ancestor=True)
    _safe_entry(root, directory=True)
    manifest_path = root / "release-manifest.json"
    _safe_entry(manifest_path)
    if manifest_path.stat().st_size > 1024 * 1024:
        raise ValueError("guest source release manifest exceeds its bound")
    verify_signature(manifest_path, HOST_ID + ".release-manifest", True)
    manifest = json.loads(manifest_path.read_bytes())
    if manifest.get("schema_version") != 1 or manifest.get("signing_mode") != "developer_id":
        raise ValueError("guest reuse requires an existing Developer ID release")
    inventory = file_inventory(root)
    inventory.pop("release-manifest.json", None)
    if inventory != manifest.get("files"):
        raise ValueError("guest source release differs from its signed manifest")
    guest = root / "guest"
    _safe_entry(guest, directory=True)
    if set(os.listdir(guest)) != set(GUEST_FILES):
        raise ValueError("guest source must contain exactly the four qualified payloads")
    hashes = {}
    for name in GUEST_FILES:
        source = guest / name
        _safe_entry(source)
        hashes[name] = inventory["guest/" + name]
    verify_signature(guest / "darkbloom-sandbox-guest", GUEST_ID, True)
    return {"kind": "reused_signed_release", "source_release": str(root),
            "source_manifest_sha256": sha256(manifest_path), "files": hashes}


def copy_guest_release(path, destination, expected=None):
    before = validate_guest_release(path)
    if expected is not None and before != expected:
        raise ValueError("guest source release changed during packaging")
    destination = Path(destination)
    destination.mkdir(mode=0o755, exist_ok=False)
    source = Path(before["source_release"]) / "guest"
    for name in GUEST_FILES:
        # ditto preserves signing xattrs and executable metadata. In particular,
        # never invoke codesign --force on a qualified guest during host updates.
        run(["/usr/bin/ditto", "--rsrc", "--extattr", source / name, destination / name])
        _safe_entry(destination / name)
        if sha256(destination / name) != before["files"][name]:
            raise ValueError("copied guest bytes differ from the qualified release")
    verify_signature(destination / "darkbloom-sandbox-guest", GUEST_ID, True)
    if validate_guest_release(path) != before:
        raise ValueError("guest source release changed while copying")
    return before
