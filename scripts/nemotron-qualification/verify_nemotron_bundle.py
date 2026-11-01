"""Offline publication preflight for the unchanged NVIDIA NVFP4 checkpoint.

This validates bytes, not inference or permission to publish. No network/writes.
The complete index is mandatory: MTP must travel in the same repository snapshot.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import stat

REVISION = "7d4bc747b6bdc2cff64c58d65da0d08dd9caa25c"
INDEX_SHA256 = "c368acdbcfe882236af1ec79df4a1fb6127e6ed9f742d59c01c21fe96ddc2741"
MANIFEST_SHA256 = "f4d008e3f6c7d91b55797b545ea99b0204ac86ef2e06999f6c1c9f570783966a"
MTP_PREFIX = "language_model.mtp."


def digest_regular(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as stream:
        before = os.fstat(stream.fileno())
        if not stat.S_ISREG(before.st_mode):
            raise ValueError(f"not a regular file: {path.name}")
        digest = hashlib.sha256()
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
        after = os.fstat(stream.fileno())
        if (before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (
            after.st_size, after.st_mtime_ns, after.st_ctime_ns
        ):
            raise ValueError(f"file changed during verification: {path.name}")
        return before.st_size, digest.hexdigest()


def plan(index_path, manifest_path):
    raw = index_path.read_bytes()
    if hashlib.sha256(raw).hexdigest() != INDEX_SHA256:
        raise ValueError("index differs from the pinned complete NVIDIA checkpoint")
    weights = json.loads(raw)["weight_map"]
    manifest_raw = manifest_path.read_bytes()
    if hashlib.sha256(manifest_raw).hexdigest() != MANIFEST_SHA256:
        raise ValueError("shard manifest differs from pinned source evidence")
    manifest = json.loads(manifest_raw)
    entries = {item["path"]: item for item in manifest}
    if len(entries) != len(manifest):
        raise ValueError("duplicate shard in manifest")
    if set(entries) != set(weights.values()) or len(entries) != 88:
        raise ValueError("manifest must contain all 88 indexed shards, including MTP")
    for name, entry in entries.items():
        if Path(name).name != name or not name.endswith(".safetensors"):
            raise ValueError("unsafe shard path")
        if entry["size"] != entry["lfs"]["size"]:
            raise ValueError("inconsistent shard size")
    mtp = {key: value for key, value in weights.items() if key.startswith(MTP_PREFIX)}
    if len(mtp) != 4120:
        raise ValueError("incomplete MTP tensor inventory")
    return entries, {
        "source_revision": REVISION,
        "index_sha256": INDEX_SHA256,
        "shards": len(entries),
        "weight_bytes": sum(item["size"] for item in entries.values()),
        "mtp_tensor_count": len(mtp),
        "mtp_shards": sorted(set(mtp.values())),
        "separate_mtp_download_required": False,
        "payload_verified": False,
        "inference_qualified": False,
    }


def verify_payload(directory, entries):
    for name, item in sorted(entries.items()):
        size, digest = digest_regular(directory / name)
        if size != item["size"] or digest != item["lfs"]["oid"]:
            raise ValueError(f"shard size/hash mismatch: {name}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--index", required=True, type=Path)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--weights", type=Path,
                        help="Hash every shard; omit for metadata-only planning")
    args = parser.parse_args()
    entries, report = plan(args.index, args.manifest)
    if args.weights:
        _, index_hash = digest_regular(args.weights / "model.safetensors.index.json")
        if index_hash != INDEX_SHA256:
            raise ValueError("bundle index differs from pinned index")
        verify_payload(args.weights, entries)
        report["payload_verified"] = True
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
