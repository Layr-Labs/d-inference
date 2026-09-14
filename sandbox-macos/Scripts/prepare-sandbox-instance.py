#!/usr/bin/env python3
"""Create private per-instance APFS materials as the dedicated host broker."""

import argparse
import base64
import json
import os
from pathlib import Path
import secrets
import shlex
import subprocess
import sys
import uuid

sys.dont_write_bytecode = True

from sandbox_release_support import PACKAGE, new_directory, require_encrypted_backing, write_json


GIB = 1024 ** 3


def validate_configuration(value: dict):
    if value.get("version") != 1 or value.get("workspacePath") != "/workspace":
        raise ValueError("unsupported instance configuration")
    uuid.UUID(value["instanceID"])
    if value.get("tenantUID") != 2001 or value.get("tenantGID") != 2001:
        raise ValueError("unsupported tenant identity")
    if value.get("workspaceDiskBytes") not in [25 * GIB, 50 * GIB]:
        raise ValueError("workspace must use the supported 25 or 50 GiB disk capacity")
    credential = base64.b64decode(value["credential"], validate=True)
    if len(credential) != 32:
        raise ValueError("credential must contain exactly 32 random bytes")
    return credential


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--instance-id", type=uuid.UUID, default=None)
    parser.add_argument("--workspace-gib", type=int, choices=[25, 50], default=25)
    parser.add_argument("--plan-only", action="store_true", help="generate private inputs without creating images")
    args = parser.parse_args()
    if os.getuid() in [0, 2001] or os.getgid() == 0:
        parser.error("broker must be non-root and must not use the guest tenant UID2001")
    backing = require_encrypted_backing(args.output.absolute().parent)
    output = new_directory(args.output)
    credential = base64.b64encode(secrets.token_bytes(32)).decode()
    configuration = {"version": 1, "instanceID": str(args.instance_id or uuid.uuid4()),
                     "credential": credential, "workspacePath": "/workspace",
                     "workspaceDiskBytes": args.workspace_gib * GIB,
                     "tenantUID": 2001, "tenantGID": 2001}
    validate_configuration(configuration)
    write_json(output / "instance.private.json", configuration)
    (output / "instance.private.json").chmod(0o600)
    with (output / "guest.credential").open("x") as stream:
        stream.write(credential + "\n")
    (output / "guest.credential").chmod(0o600)
    write_json(output / "broker.json", {"version": 1, "instanceID": configuration["instanceID"],
                                      "credential": credential})
    (output / "broker.json").chmod(0o600)
    plan = {"schema_version": 1, "instanceID": configuration["instanceID"],
            "broker_uid": os.getuid(), "broker_gid": os.getgid(),
            "workspace_bytes": configuration["workspaceDiskBytes"],
            "control_bytes": 128 * 1024 ** 2, "minimum_free_bytes": 20 * GIB,
            "image_encryption": "none", "backing_volume_encryption": backing, "materialized": False,
            "control_attachment_read_only_required": True}
    write_json(output / "materialization-plan.json", plan)
    command = [sys.executable, str(Path(__file__).resolve().with_name("materialize-sandbox-instance.py")),
               "--directory", str(output)]
    instructions = (
        "# Per-instance materialization\n\n"
        "The private configuration and credential have been generated, but no image is created.\n"
        "Review the materializer and run this exact command as the same dedicated broker identity:\n\n"
        "```sh\n" + shlex.join(command) + "\n```\n\n"
        "It creates only DBCONTROL and DBWORK disk images in this directory; it installs no service.\n"
        "It requires at least the full image sizes plus20GiB of free storage. Control APFS contents\n"
        "are broker-owned0600; guest root copies them into root-owned0600 state. The guest rejects\n"
        "a source owner matching its tenant or any existing non-root account. The broker reads\n"
        "broker.json; never put its credential value in arguments.\n"
        "The raw images have no per-image encryption; backing FileVault encryption is required.\n"
        "The artifact codec and per-VM cryptoerase are separate. DBCONTROL must attach read-only.\n"
    )
    (output / "MATERIALIZATION_PLAN.md").write_text(instructions)
    if not args.plan_only:
        subprocess.run(command, check=True, stdout=subprocess.DEVNULL)
    print(json.dumps({"instanceID": configuration["instanceID"], "directory": str(output),
                      "manifest": str(output / "material-manifest.json") if not args.plan_only else None,
                      "materialized": not args.plan_only, "credential_disclosed": False}))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f"instance preparation failed: {error}", file=sys.stderr)
        sys.exit(1)
