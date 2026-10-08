"""Atomically stage one immutable analytics snapshot from private Cloud Storage."""

import hashlib
import json
import os
import re
import tempfile
from pathlib import Path

from . import cloud
from .model import ArchiveError
from .objects import archive_bucket

MAX_BYTES = 8 * 1024**2


def sync_snapshot(args):
    if not args.output.is_absolute():
        raise ArchiveError("snapshot output path must be absolute")
    bucket = archive_bucket(cloud.storage_client(args.project), args.bucket, args.location)
    if bucket.labels.get("archive-scope") != "accounting":
        raise ArchiveError("analytics snapshot requires the private accounting bucket")
    pointer = bucket.get_blob("analytics/v1/current.json", timeout=30)
    if pointer is None or pointer.size > 4096:
        raise ArchiveError("missing or oversized analytics pointer")
    meta = json.loads(pointer.download_as_bytes(if_generation_match=pointer.generation, timeout=30))
    digest = meta.get("sha256", "")
    if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
        raise ArchiveError("invalid analytics snapshot digest")
    if meta.get("name") != f"analytics/v1/snapshots/{digest}.json":
        raise ArchiveError("analytics pointer names an unexpected object")
    blob = bucket.get_blob(meta["name"], timeout=30)
    if blob is None or blob.size > MAX_BYTES or str(blob.generation) != str(meta.get("generation")):
        raise ArchiveError("analytics snapshot is missing, oversized or replaced")
    raw = blob.download_as_bytes(if_generation_match=blob.generation, timeout=30)
    if hashlib.sha256(raw).hexdigest() != digest:
        raise ArchiveError("analytics snapshot checksum mismatch")
    # Coordinator performs the complete serving contract/freshness validation.
    document = json.loads(raw)
    if document.get("schema_version") != 1 or document.get("source_complete") is not True:
        raise ArchiveError("analytics snapshot is not qualified for serving")
    fd, tmp = tempfile.mkstemp(prefix=".analytics-", dir=args.output.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(raw)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(tmp, args.output)
        directory_fd = os.open(args.output.parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        Path(tmp).unlink(missing_ok=True)
    return {"synced": True, "generation": document.get("generation"), "sha256": digest}
