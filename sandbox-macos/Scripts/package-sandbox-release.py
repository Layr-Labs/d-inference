#!/usr/bin/env python3
"""Build and stage sandbox host/guest artifacts without installing them."""

import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import sys

from sandbox_release_support import (
    PACKAGE, HOST_ID, GUEST_ID, TEAM, IDENTITY, file_inventory, new_directory,
    read_profile, run, sign, validate_lume, write_json,
)
from sandbox_guest_release import copy_guest_release, validate_guest_release


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="new staging directory")
    parser.add_argument("--sign", action="store_true", help="use Developer ID; default is ad-hoc")
    parser.add_argument("--identity", default=IDENTITY)
    parser.add_argument("--profile", type=Path, help="sandbox-specific Developer ID profile")
    parser.add_argument("--lume-runtime", type=Path, help="existing complete pinned immutable tree")
    parser.add_argument("--guest-release", type=Path,
                        help="reuse four exact guest artifacts from an existing signed release without re-signing")
    parser.add_argument("--binary-directory", type=Path, help="stage already-built release binaries")
    parser.add_argument("--jobs", type=int, default=4)
    args = parser.parse_args()
    if args.jobs < 1 or args.jobs > 32:
        parser.error("--jobs must be between 1 and 32")
    if args.profile and not args.sign:
        parser.error("--profile requires --sign")
    if args.sign and args.identity == "-":
        parser.error("--sign cannot select an ad-hoc identity")
    profile_metadata = read_profile(args.profile)[1] if args.profile else None
    lume_metadata = validate_lume(args.lume_runtime, args.sign) if args.lume_runtime else None
    guest_metadata = validate_guest_release(args.guest_release) if args.guest_release else None
    output = new_directory(args.output)
    identity = args.identity if args.sign else "-"
    if args.binary_directory:
        binaries = args.binary_directory.resolve()
    else:
        build = ["xcrun", "swift", "build", "--package-path", PACKAGE, "-c", "release", "-j", args.jobs]
        if args.guest_release:
            build += ["--product", "darkbloom-sandboxd"]
        run(build)
        binaries = Path(run(["xcrun", "swift", "build", "--package-path", PACKAGE,
                             "-c", "release", "--show-bin-path"],
                            capture_output=True, text=True).stdout.strip())
    for name in ["darkbloom-sandboxd"] + ([] if args.guest_release else ["darkbloom-sandbox-guest"]):
        source = binaries / name
        if not source.is_file() or not os.access(source, os.X_OK):
            raise ValueError(f"required release executable is absent: {source}")

    app = output / "DarkbloomSandbox.app"
    contents = app / "Contents"
    executable_directory = contents / "MacOS"
    executable_directory.mkdir(parents=True)
    shutil.copy2(binaries / "darkbloom-sandboxd", executable_directory / "darkbloom-sandboxd")
    version = run([binaries / "darkbloom-sandboxd", "version"],
                  capture_output=True, text=True).stdout.strip().split()[-1]
    info = {
        "CFBundleIdentifier": HOST_ID, "CFBundleName": "DarkbloomSandbox",
        "CFBundleExecutable": "darkbloom-sandboxd", "CFBundlePackageType": "APPL",
        "CFBundleVersion": version, "CFBundleShortVersionString": version,
        "LSMinimumSystemVersion": "14.0", "LSUIElement": True,
    }
    (contents / "Info.plist").write_bytes(plistlib.dumps(info))
    entitlement_source = PACKAGE / "Resources/DarkbloomSandboxDevelopment.entitlements"
    entitlements = plistlib.loads(entitlement_source.read_bytes())
    if args.profile:
        entitlements = plistlib.loads((PACKAGE / "Resources/DarkbloomSandbox.entitlements").read_bytes())
        entitlements["com.apple.application-identifier"] = TEAM + "." + HOST_ID
        entitlements["com.apple.developer.team-identifier"] = TEAM
        shutil.copy2(args.profile, contents / "embedded.provisionprofile")
    entitlement_path = output / "host-signing.entitlements"
    entitlement_path.write_bytes(plistlib.dumps(entitlements))
    sign(app, HOST_ID, identity, entitlement_path)

    guest_directory = output / "guest"
    if args.guest_release:
        guest_metadata = copy_guest_release(args.guest_release, guest_directory, expected=guest_metadata)
    else:
        guest_directory.mkdir()
        guest = guest_directory / "darkbloom-sandbox-guest"
        shutil.copy2(binaries / guest.name, guest)
        sign(guest, GUEST_ID, identity)
        shutil.copy2(PACKAGE / "Resources/io.darkbloom.sandbox.guest.plist", guest_directory)
        shutil.copy2(PACKAGE / "Scripts/install-sandbox-guest.sh", guest_directory)
        shutil.copy2(PACKAGE / "Resources/darkbloom-sandbox-bootstrap.sh", guest_directory)
        guest_metadata = {"kind": "built", "signing_mode": "developer_id" if args.sign else "development_ad_hoc"}
    if args.lume_runtime:
        # ditto retains the detached manifest's signing xattrs. Never re-sign Lume.
        run(["/usr/bin/ditto", "--rsrc", "--extattr", args.lume_runtime, output / "lume"])
        validate_lume(output / "lume", args.sign)
    tools_directory = output / "tools"
    tools_directory.mkdir()
    for name in ["prepare-sandbox-instance.py", "materialize-sandbox-instance.py", "sandbox_release_support.py"]:
        shutil.copy2(PACKAGE / "Scripts" / name, tools_directory)
    shutil.copy2(PACKAGE / "Resources/RELEASE_VALIDATION.md", output)
    commit = run(["git", "-C", PACKAGE, "rev-parse", "HEAD"],
                 capture_output=True, text=True).stdout.strip()
    dirty = bool(run(["git", "-C", PACKAGE, "status", "--porcelain", "--", "."],
                     capture_output=True, text=True).stdout.strip())
    manifest = {
        "schema_version": 1, "source_commit": commit, "source_dirty": dirty,
        "binary_source": str(binaries), "version": version,
        "signing_mode": "developer_id" if args.sign else "development_ad_hoc",
        "provisioning": profile_metadata, "lume": lume_metadata, "guest_origin": guest_metadata,
        "notarization": "not_performed", "production_keychain_test": "not_performed",
        "physical_isolation_tests": "not_performed", "installation": "not_performed",
        "production_ready": False,
        "files": file_inventory(output),
    }
    write_json(output / "release-manifest.json", manifest)
    # Covers bootstrap scripts and packaging metadata as well as signed binaries.
    sign(output / "release-manifest.json", HOST_ID + ".release-manifest", identity)
    print(json.dumps({"package": str(output), "manifest": str(output / "release-manifest.json"),
                      "signing_mode": manifest["signing_mode"], "production_ready": False}))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError) as error:
        print(f"release preparation failed: {error}", file=sys.stderr)
        sys.exit(1)
