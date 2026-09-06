#!/usr/bin/env python3
"""Record public provenance only, after the workflow's full qualification gate."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import uuid


# These are the exact post-staple distributions, never the notary submission ZIP.
ARCHIVES = {
    "Darkbloom-macOS-arm64.zip": "APP_ARCHIVE_HASH",
    "darkbloom-bundle-macos-arm64.tar.gz": "BUNDLE_HASH",
}


def qualification_manifest(artifact_dir, notary_result, env):
    if (env["GITHUB_EVENT_NAME"], env["ENV_PREFIX"], env["PUBLISH_RELEASE"]) != (
        "workflow_dispatch", "dev", "false"
    ):
        raise ValueError("Qualification artifacts require a nonpublishing dev dispatch")
    # Do not serialize Apple's entire response: messages/logs may include
    # account details. Accept only a submission UUID and the literal status.
    if notary_result.get("status") != "Accepted":
        raise ValueError("Qualification requires accepted notarization")
    submission_id = str(uuid.UUID(notary_result["id"]))
    archives = []
    for name, hash_key in ARCHIVES.items():
        path = artifact_dir / name
        if path.is_symlink() or not path.is_file() or path.stat().st_size == 0:
            raise ValueError(f"Missing regular qualification archive: {name}")
        digest = hashlib.sha256()
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
        if digest.hexdigest() != env[hash_key]:
            raise ValueError(f"Qualified archive hash changed: {name}")
        archives.append({
            "name": name,
            "sha256": digest.hexdigest(),
            "size_bytes": path.stat().st_size,
        })
    # Fixed field allowlist: no environment dump, credentials, signing files,
    # raw notary response, registration payload, tag message, or filesystem paths.
    return {
        "schema_version": 1,
        "environment": "dev",
        "publish_release": False,
        "version": env["VERSION"],
        "source": {
            "repository": env["GITHUB_REPOSITORY"],
            "sha": env["GITHUB_SHA"],
            "ref": env["GITHUB_REF"],
            "workflow_ref": env["GITHUB_WORKFLOW_REF"],
            "workflow_sha": env["GITHUB_WORKFLOW_SHA"],
            "run_id": env["GITHUB_RUN_ID"],
            "run_attempt": env["GITHUB_RUN_ATTEMPT"],
        },
        "notarization": {"id": submission_id, "status": "Accepted"},
        "archives": archives,
        "binary_sha256": env["BINARY_HASH"],
        "metallib_sha256": env["METALLIB_HASH"],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifact-dir", type=Path, required=True)
    parser.add_argument("--notary-result", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    notary_result = json.loads(args.notary_result.read_text(encoding="utf-8"))
    manifest = qualification_manifest(args.artifact_dir, notary_result, os.environ)
    args.output.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
