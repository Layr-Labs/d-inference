#!/usr/bin/env python3
"""Prepare launchd configuration and a reviewable host installation plan.

No account, ownership, process, VM, or service mutations are performed.
"""

import argparse
import ipaddress
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import stat
import sys
import urllib.parse
import uuid

from sandbox_release_support import (
    HOST_ID, file_inventory, new_directory, validate_lume, verify_signature, write_json,
)
from sandbox_install_validation import require_no_extended_acl, validate_artifact_layout, validate_install_ancestors
from sandbox_broker_identity import BROKER_NAME, validate_broker_account


BROKER = BROKER_NAME


def activation_commands(configuration: dict, install_root: Path):
    # Generate only. The caller's host, services and ownership lock are untouched.
    host_arguments(configuration, install_root)
    return [
        ["/bin/launchctl", "bootout", "system/" + HOST_ID],
        ["/usr/bin/sudo", "-u", BROKER, "--",
         str(install_root / "DarkbloomSandbox.app/Contents/MacOS/darkbloom-sandboxd"),
         "host-mode", "--storage", configuration["storageDirectory"],
         "--capacity-dir", configuration["capacityDirectory"], "--mode", "sandbox_dedicated"],
        ["/bin/launchctl", "bootstrap", "system", "/Library/LaunchDaemons/" + HOST_ID + ".plist"],
    ]


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
            "serve", "--coordinator", configuration["coordinatorURL"], "--host-id", host_id,
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
    args = parser.parse_args()
    if not args.install_root.is_absolute() or ".." in args.install_root.parts:
        parser.error("--install-root must be absolute and contain no traversal")
    configuration = json.loads(args.configuration.read_text())
    arguments = host_arguments(configuration, args.install_root)
    manifest = validate_package(args.package)
    if args.verify_installed:
        validate_package(args.install_root)
        broker = validate_broker_account()
        validate_install_ancestors(args.install_root)
        validate_artifact_layout(args.install_root)
        for key, mode in [("tokenFile", 0o600), ("storageDirectory", 0o700), ("capacityDirectory", 0o700)]:
            path = Path(configuration[key])
            metadata = path.lstat()
            if path.is_symlink() or metadata.st_uid != broker.uid or stat.S_IMODE(metadata.st_mode) != mode:
                raise ValueError(f"unsafe installed {key}")
            if key == "tokenFile":
                if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
                    raise ValueError("installed token must be a single-link regular file")
            elif not stat.S_ISDIR(metadata.st_mode):
                raise ValueError(f"installed {key} must be a directory")
            require_no_extended_acl(path)
        print(json.dumps({"installed_layout_validated": True, "broker_account_policy_validated": True,
                          "production_ready": False,
                          "not_verified": ["Aqua access", "keychain persistence", "network policy", "live isolation"]}))
        return
    if not args.output:
        parser.error("preparation requires --output")
    output = new_directory(args.output)
    launchd = {
        "Label": HOST_ID, "ProgramArguments": arguments,
        "UserName": BROKER, "GroupName": BROKER,
        "RunAtLoad": True, "KeepAlive": True, "ThrottleInterval": 30,
        "ProcessType": "Background", "Umask": 63,
        "EnvironmentVariables": {"LUME_TELEMETRY_ENABLED": "false", "LUME_LOG_LEVEL": "error"},
    }
    (output / (HOST_ID + ".plist")).write_bytes(plistlib.dumps(launchd))
    quote = lambda value: shlex.quote(str(value))
    activation = activation_commands(configuration, args.install_root)
    activation_script = "\n".join(shlex.join(command) for command in activation)
    (output / "activate-sandbox-offline.sh").write_text("""#!/bin/zsh
# Prepared operator action. No action occurs until explicitly invoked.
set -euo pipefail
[[ $# == 1 && $1 == --activate ]] || { print -u2 'usage: activate-sandbox-offline.sh --activate'; exit 64; }
[[ $EUID == 0 ]] || { print -u2 'offline activation requires an authorized root operator'; exit 77; }
# bootout prevents KeepAlive from reacquiring EX. A failed mode transition
# leaves the service offline and never stops an inference provider.
""" + activation_script + "\n")
    (output / "activate-sandbox-offline.sh").chmod(0o700)
    plan = f"""# Prepared host installation

This plan does not authorize or perform host mutations. Use a sandbox-only Mac.
The package is version {manifest['version']}; signature/profile checks passed.
Notarization, persistent Secure Enclave key storage and physical isolation are
separate validation gates and are not established by this plan.

1. Allocate an unused system UID/GID for `{BROKER}` and create a hidden account
   with disabled authentication, a non-login shell and `/var/empty` as its home.
   Exclude explicit administrator, wheel and other privileged memberships;
   permit only intended service memberships. Verify both explicit and resolved
   groups: macOS can give nonadmin accounts ambient local-account, public-share
   and print-operator access through nested groups. `InitGroups=false` does not
   establish removal of that access. This trusted nonadmin host service retains
   access to other host files permitted by Unix permissions. `sandbox_dedicated`
   controls workload
   admission and machine ownership; it does not change Unix permissions.
   Do not share this identity with the inference provider or tenant workloads.
2. Provision a dedicated `darkbloom_runtime` group with an unused nonzero GID;
   add only the sandbox broker and intended provider service identities. Create
   `/Library/Application Support/Darkbloom/runtime` as root:darkbloom_runtime
   mode 0750, with no extended ACL and root-owned ancestors without shared write
   access. Create its EMPTY `ownership.lock` once, root:darkbloom_runtime mode
   0660, regular and single-link. Never truncate or replace an existing lock.
   A provider started before this authority existed must be upgraded/restarted
   through a separate authorized transition before sandbox activation. Group
   membership must be effective in both newly launched services.
3. Copy the complete package with `/usr/bin/ditto --rsrc --extattr`
   from {quote(args.package)} to the new destination {quote(args.install_root)}.
   Preserve signature xattrs and the pinned Lume tree; do not re-sign Lume.
   Make the installed tree recursively root:wheel. The staging root is PRIVATE
   0700: explicitly set the installed root and all non-Lume directories to 0755,
   non-Lume regular data files to 0644, and non-Lume executable files to 0755.
   Determine executable files from the signed source package, never make every
   file executable. Keep the entire pinned Lume subtree at its exact immutable
   0555-directory/executable and 0444-data modes. Do not alter signing xattrs.
   Reject extended ACLs. The root-owned ancestors must also permit broker
   traversal and reject shared writes/ACLs. These public-code modes DO NOT apply
   to private state or token paths in step 4.
4. Create {quote(configuration['storageDirectory'])} and
   {quote(configuration['capacityDirectory'])}, owned by `{BROKER}` mode 0700,
   on APFS with no extended ACLs and sufficient admission headroom. Enroll a
   dedicated host token into {quote(configuration['tokenFile'])}, owned by
   `{BROKER}` mode 0600. Never put a token in launchd arguments or environment.
5. Install the generated {HOST_ID}.plist as root:wheel mode 0644 under
   /Library/LaunchDaemons. Validate the installed layout with this tool's
   `--verify-installed` option as root before starting it. This protected
   account-policy read must prove disabled authentication, hidden/nonlogin
   settings, /var/empty home, runtime-group membership and no admin/wheel
   membership; missing or unrecognized data fails verification.
6. Run the signed host doctor as the broker and prove keychain persistence with
   the provisioned identity. Retain outputs with the release evidence.
7. A newly initialized capacity store begins in draining mode. Bootstrap this
   service once to initialize it and collect readiness/doctor evidence, keeping
   coordinator admission disabled. The broker holds machine EX ownership even
   while draining, so an online `host-mode --mode sandbox_dedicated` cannot
   acquire the required lease.
8. Activation is OFFLINE and requires the separately authorized operator. With
   no tenant work and all readiness gates satisfied, run the prepared
   `activate-sandbox-offline.sh --activate` as root. Its exact sequence is:

```sh
{activation_script}
```

   `bootout` removes the service from launchd; killing its PID would let
   `KeepAlive` immediately reacquire EX. Wait for proven VM cleanup: an actual
   surviving VM retains EX and causes `host-mode` to fail closed. The mode change
   runs as the broker so private capacity-state ownership remains correct. The
   final bootstrap happens only after the mode change succeeds. If the service
   is already unloaded, first prove that offline state and execute only the
   remaining two commands; the generated script deliberately stops on bootout
   errors. Never stop inference or other VMs as part of sandbox activation.

Guest image preparation uses the signed guest package inside a fresh VM. The
guest installer refuses physical hosts and leaves launchd stopped. Bootstrap
requires unique DBCONTROL and DBWORK disks before it starts the guest agent.
"""
    (output / "INSTALLATION_PLAN.md").write_text(plan)
    write_json(output / "plan.json", {"schema_version": 1, "installed": False,
               "broker": BROKER, "install_root": str(args.install_root),
               "program_arguments": arguments, "offline_activation_commands": activation,
               "production_ready": False})
    print(json.dumps({"plan": str(output / "INSTALLATION_PLAN.md"), "installed": False}))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError) as error:
        print(f"host preparation failed: {error}", file=sys.stderr)
        sys.exit(1)
