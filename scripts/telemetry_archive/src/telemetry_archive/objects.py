"""Create-only GCS uploads and generation-pinned download verification."""

import hashlib
import json
import re
import tempfile
from pathlib import Path
from urllib.parse import urlsplit

from google.api_core.exceptions import PreconditionFailed

from .artifact import json_bytes, read_artifact, validate_receipt
from .codec import file_sha256, verify_parquet
from .model import ArchiveError


def archive_bucket(client, name: str, location: str):
    if not re.fullmatch(r"[a-z0-9][a-z0-9._-]{1,220}[a-z0-9]", name):
        raise ArchiveError("invalid bucket name")
    bucket = client.get_bucket(name)
    if bucket.storage_class != "STANDARD" or bucket.location.lower() != location.lower():
        raise ArchiveError("archive bucket must use Standard storage in the requested region")
    iam = bucket.iam_configuration
    if not iam.uniform_bucket_level_access_enabled or iam.public_access_prevention != "enforced":
        raise ArchiveError("archive bucket must enforce private uniform bucket access")
    if list(bucket.lifecycle_rules):
        raise ArchiveError("copy-only archive bucket must not have lifecycle rules")
    return bucket


def put_verified(bucket, name: str, path: Path, *, content_type: str) -> dict:
    expected = file_sha256(path)
    blob = bucket.blob(name)
    blob.metadata = {"sha256": expected, "copy_only": "true"}
    try:
        # The SDK's upload checksum recovery can issue object DELETE. Disable
        # that recovery path and instead download + SHA256 every object below.
        blob.upload_from_filename(
            str(path),
            content_type=content_type,
            if_generation_match=0,
            checksum=None,
            timeout=120,
        )
    except PreconditionFailed:
        # A previous attempt may already have committed this immutable object.
        pass
    blob.reload(timeout=30)
    generation = int(blob.generation)
    if blob.size != path.stat().st_size or (blob.metadata or {}).get("sha256") != expected:
        raise ArchiveError("existing or uploaded object does not match the artifact")
    with tempfile.TemporaryDirectory(prefix="archive-verify-") as tmp:
        downloaded = Path(tmp) / "object"
        blob.download_to_filename(
            str(downloaded),
            if_generation_match=generation,
            checksum="auto",
            timeout=120,
        )
        if file_sha256(downloaded) != expected:
            raise ArchiveError("downloaded object checksum mismatch")
    return {"name": name, "generation": generation, "sha256": expected, "bytes": blob.size}


def upload(directory: Path, client, bucket_name: str, location: str) -> dict:
    receipt, window = read_artifact(directory)
    if receipt["source"]["in_recovery"] is not True or receipt["source"]["read_only"] != "on":
        raise ArchiveError("only snapshots captured from a physical read replica can be uploaded")
    bucket = archive_bucket(client, bucket_name, location)
    name = (
        f"data/v1/{window.table}/event_date={window.date}/{receipt['stats']['file_sha256']}.parquet"
    )
    data = put_verified(
        bucket, name, directory / "data.parquet", content_type="application/octet-stream"
    )
    with tempfile.TemporaryDirectory(prefix="archive-publish-") as tmp:
        root = Path(tmp)
        manifest_path = root / "manifest.txt"
        manifest_path.write_text(f"gs://{bucket_name}/{name}\n")
        manifest = put_verified(
            bucket,
            f"manifests/v1/{receipt['artifact_id']}.txt",
            manifest_path,
            content_type="text/plain",
        )
        # The remote receipt is the last commit marker; it is not retention permission.
        published = {
            "snapshot": receipt,
            "bucket": bucket_name,
            "location": location,
            "data": data,
            "manifest": manifest,
        }
        publication_path = root / "published.json"
        publication_path.write_bytes(json_bytes(published))
        published_object = put_verified(
            bucket,
            f"receipts/v1/{receipt['artifact_id']}.json",
            publication_path,
            content_type="application/json",
        )
    return {"receipt_uri": f"gs://{bucket_name}/{published_object['name']}", **published}


def load_remote(client, uri: str, location: str) -> tuple[dict, object]:
    parsed = urlsplit(uri)
    if parsed.scheme != "gs" or parsed.query or parsed.fragment:
        raise ArchiveError("expected a gs:// receipt URI without query or fragment")
    if not re.fullmatch(r"/receipts/v1/[0-9a-f]{64}\.json", parsed.path):
        raise ArchiveError("expected an archive receipt object")
    bucket = archive_bucket(client, parsed.netloc, location)
    blob = bucket.get_blob(parsed.path.lstrip("/"), timeout=30)
    if blob is None or blob.size > 2 * 1024 * 1024:
        raise ArchiveError("receipt is missing or too large")
    raw = blob.download_as_bytes(if_generation_match=int(blob.generation), timeout=30)
    if hashlib.sha256(raw).hexdigest() != (blob.metadata or {}).get("sha256"):
        raise ArchiveError("remote receipt checksum mismatch")
    published = json.loads(raw)
    snapshot = published["snapshot"]
    window = validate_receipt(snapshot)
    artifact_id = snapshot["artifact_id"]
    expected_data = (
        f"data/v1/{window.table}/event_date={window.date}/"
        f"{snapshot['stats']['file_sha256']}.parquet"
    )
    if (
        parsed.path != f"/receipts/v1/{artifact_id}.json"
        or published["bucket"] != parsed.netloc
        or published["location"].lower() != location.lower()
        or published["data"]["name"] != expected_data
        or published["manifest"]["name"] != f"manifests/v1/{artifact_id}.txt"
    ):
        raise ArchiveError("receipt contains unexpected object locations")
    with tempfile.TemporaryDirectory(prefix="archive-readback-") as tmp:
        for kind in ("data", "manifest"):
            entry = published[kind]
            current = bucket.get_blob(entry["name"], timeout=30)
            if current is None or int(current.generation) != entry["generation"]:
                raise ArchiveError("published object was replaced or is missing")
            if current.size != entry["bytes"] or current.size > 2 * 1024**3:
                raise ArchiveError("published object size mismatch")
            path = Path(tmp) / kind
            current.download_to_filename(
                str(path),
                if_generation_match=entry["generation"],
                timeout=120,
            )
            if file_sha256(path) != entry["sha256"]:
                raise ArchiveError("remote content checksum mismatch")
            if kind == "data":
                verify_parquet(path, window, snapshot["stats"])
            elif path.read_text() != f"gs://{parsed.netloc}/{expected_data}\n":
                raise ArchiveError("manifest does not name exactly the verified data object")
    return published, bucket


def check_generations(bucket, published: dict) -> None:
    """Fence a BigQuery result against object replacement while the job ran."""
    for kind in ("data", "manifest"):
        expected = published[kind]
        blob = bucket.get_blob(expected["name"], timeout=30)
        if blob is None or int(blob.generation) != expected["generation"]:
            raise ArchiveError("published object changed during BigQuery verification")
