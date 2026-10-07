"""Immutable create-only checkpoint objects; first completed writer wins."""

import hashlib
import json
import re

from google.api_core.exceptions import PreconditionFailed

from .artifact import json_bytes
from .model import ArchiveError

CONTROL_OBJECT_MAX_BYTES = 2 * 1024**2


def catalog_objects(catalog: dict):
    """Keep legacy catalogs intact; split oversized inventories into bounded objects."""
    key = "catalogs/" + catalog["table"]
    if len(json_bytes(catalog)) <= CONTROL_OBJECT_MAX_BYTES:
        yield key, catalog
        return

    header = {field: catalog[field] for field in ("plan_id", "table", "copy_only")}

    def split(files):
        shard = {**header, "files": files}
        if len(json_bytes(shard)) <= CONTROL_OBJECT_MAX_BYTES:
            yield shard
        elif len(files) <= 1:
            raise ArchiveError("catalog entry exceeds the control object size limit")
        else:
            middle = len(files) // 2
            yield from split(files[:middle])
            yield from split(files[middle:])

    shards = []
    for index, shard in enumerate(split(catalog["files"])):
        shard_key = f"{key}/shards/{index:06d}"
        shards.append(
            {
                "key": shard_key,
                "file_count": len(shard["files"]),
                "sha256": hashlib.sha256(json_bytes(shard)).hexdigest(),
            }
        )
        yield shard_key, shard
    yield (
        key,
        {
            **{field: value for field, value in catalog.items() if field != "files"},
            "format_version": 2,
            "file_count": len(catalog["files"]),
            "shards": shards,
        },
    )


def read_json(bucket, name: str) -> dict | None:
    blob = bucket.get_blob(name, timeout=30)
    if blob is None:
        return None
    if blob.size > CONTROL_OBJECT_MAX_BYTES:
        raise ArchiveError("control object exceeds the size limit")
    raw = blob.download_as_bytes(if_generation_match=int(blob.generation), timeout=30)
    if hashlib.sha256(raw).hexdigest() != (blob.metadata or {}).get("sha256"):
        raise ArchiveError("control object checksum mismatch")
    return json.loads(raw)


def create_json(bucket, name: str, value: dict) -> dict:
    raw = json_bytes(value)
    if len(raw) > CONTROL_OBJECT_MAX_BYTES:
        raise ArchiveError("control object exceeds the size limit")
    blob = bucket.blob(name)
    blob.metadata = {"sha256": hashlib.sha256(raw).hexdigest(), "copy_only": "true"}
    try:
        blob.upload_from_string(
            raw,
            content_type="application/json",
            if_generation_match=0,
            checksum=None,
            timeout=60,
        )
    except PreconditionFailed:
        # Another writer committed first; read and verify that immutable value below.
        pass
    stored = read_json(bucket, name)
    if stored is None:
        raise ArchiveError("control object was not committed")
    return stored


class Journal:
    def __init__(self, bucket, plan_id: str):
        if not re.fullmatch(r"[0-9a-f]{64}", plan_id):
            raise ArchiveError("invalid plan ID")
        self.bucket = bucket
        self.prefix = f"backfills/v1/{plan_id}/"

    def get(self, key: str):
        return read_json(self.bucket, self.prefix + key + ".json")

    def put(self, key: str, value: dict):
        return create_json(self.bucket, self.prefix + key + ".json", value)
