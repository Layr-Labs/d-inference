#!/usr/bin/env python3
"""Publish an immutable R2 revision and converge an existing model's fleet."""
import argparse
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import urllib.parse
import urllib.request
import uuid
from datetime import datetime, timezone


def identity(manifest):
    result = {key: manifest[key] for key in (
        "schema_version", "model_id", "version", "r2_prefix", "aggregate_sha256",
        "total_size_bytes", "file_count", "files")}
    result["files"] = sorted(result["files"], key=lambda item: item["path"])
    return result


def aws(args, endpoint, *, check=True):
    result = subprocess.run(["aws", *args, "--endpoint-url", endpoint, "--region", "auto"],
                            text=True, capture_output=True)
    if check and result.returncode:
        raise RuntimeError(result.stderr.strip())
    return result


def read_object(bucket, key, endpoint, directory):
    destination = Path(directory) / uuid.uuid4().hex
    result = aws(["s3api", "get-object", "--bucket", bucket, "--key", key,
                  str(destination)], endpoint, check=False)
    if result.returncode:
        if "NoSuchKey" in result.stderr or "(404)" in result.stderr:
            return None
        raise RuntimeError(result.stderr.strip())
    return destination.read_bytes()


def reserve_revision(manifest, bucket, endpoint, directory):
    """Permanent conditional reservation: identical retries resume; different
    bytes cannot race the first writer or overwrite an already published build.
    """
    prefix = manifest["r2_prefix"]
    existing = read_object(bucket, prefix + "/manifest.json", endpoint, directory)
    if existing is not None:
        if identity(json.loads(existing)) != identity(manifest):
            raise ValueError("R2 revision already contains different bytes; use a new version")
        return False
    canonical = json.dumps(identity(manifest), sort_keys=True, separators=(",", ":")).encode()
    reservation = hashlib.sha256(canonical).hexdigest().encode()
    body = Path(directory) / "reservation"
    body.write_bytes(reservation)
    key = prefix + "/.publish-reservation"
    result = aws(["s3api", "put-object", "--bucket", bucket, "--key", key,
                  "--body", str(body), "--if-none-match", "*"], endpoint, check=False)
    if result.returncode:
        # Read only on an actual conditional conflict; auth/network failures
        # must not be misclassified as an existing publish or silently ignored.
        if "PreconditionFailed" not in result.stderr and "(412)" not in result.stderr:
            raise RuntimeError(result.stderr.strip())
        existing = read_object(bucket, key, endpoint, directory)
        if existing != reservation:
            raise ValueError("R2 revision is reserved for different bytes; use a new version")
    return True


def publish_files(directory, manifest_path, manifest, bucket, endpoint):
    prefix = manifest["r2_prefix"]
    def upload(item):
        relative = Path(item["path"])
        if relative.is_absolute() or ".." in relative.parts:
            raise ValueError("unsafe manifest path")
        aws(["s3", "cp", str(directory / relative),
             f"s3://{bucket}/{prefix}/{item['path']}", "--only-show-errors"], endpoint)
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        list(pool.map(upload, manifest["files"]))
    # The final manifest is the publication boundary. Interrupted copies never
    # become a selectable revision; rerunning resumes the same reserved content.
    aws(["s3", "cp", str(manifest_path), f"s3://{bucket}/{prefix}/manifest.json",
         "--only-show-errors"], endpoint)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    reserve = commands.add_parser("reserve", help="reserve an already hashed revision for the legacy publisher")
    reserve.add_argument("--manifest", type=Path, required=True)
    publish = commands.add_parser("publish", help="hash, upload, verify and promote an existing model")
    publish.add_argument("directory", type=Path)
    publish.add_argument("model_id")
    publish.add_argument("--version", default=datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ-") + uuid.uuid4().hex[:12])
    publish.add_argument("--coordinator", required=True)
    publish.add_argument("--dry-run", action="store_true", help="hash locally and print the plan without remote changes")
    for command in (reserve, publish):
        command.add_argument("--bucket", default="darkbloom-models")
        command.add_argument("--endpoint", default=os.environ.get("R2_ENDPOINT"), required=not bool(os.environ.get("R2_ENDPOINT")))
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="darkbloom-publish-") as scratch:
        if args.command == "reserve":
            reserved = reserve_revision(json.loads(args.manifest.read_text()), args.bucket, args.endpoint, scratch)
            print("reserved" if reserved else "published")
            return
        if not args.directory.is_dir():
            parser.error("directory must contain the complete new model revision")
        if urllib.parse.urlparse(args.coordinator).scheme != "https":
            parser.error("coordinator must use https")
        key = os.environ.get("MODEL_REGISTRY_PUBLISHING_KEY")
        if not args.dry_run and not key:
            parser.error("MODEL_REGISTRY_PUBLISHING_KEY is required")
        manifest_path = Path(scratch) / "manifest.json"
        root = Path(__file__).resolve().parents[1]
        subprocess.run(["swift", "run", "darkbloom-publish", "hash", str(args.directory.resolve()),
                        "--id", args.model_id, "--version", args.version, "-o", str(manifest_path)],
                       cwd=root / "provider-swift", check=True)
        manifest = json.loads(manifest_path.read_text())
        if args.dry_run:
            print(json.dumps({"model_id": args.model_id, "version": args.version,
                              "r2_prefix": manifest["r2_prefix"], "aggregate_sha256": manifest["aggregate_sha256"],
                              "bytes": manifest["total_size_bytes"], "coordinator": args.coordinator}, indent=2))
            return
        if reserve_revision(manifest, args.bucket, args.endpoint, scratch):
            publish_files(args.directory, manifest_path, manifest, args.bucket, args.endpoint)
        url = args.coordinator.rstrip("/") + "/v1/admin/models/" + urllib.parse.quote(args.model_id, safe="") + "/publish-revision"
        request = urllib.request.Request(url, data=json.dumps({"version": args.version}).encode(),
            headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"}, method="POST")
        with urllib.request.urlopen(request, timeout=120) as response:
            print(response.read().decode())


if __name__ == "__main__":
    main()
