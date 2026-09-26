"""Streaming Parquet encoding and independent decoded-content verification."""

import hashlib
import json
from datetime import UTC
from pathlib import Path

import pyarrow as pa
import pyarrow.parquet as pq

from .model import ARCHIVE_SCHEMA, TABLES, ArchiveError, Window, stamp, utc


def file_sha256(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def digest_row(digest, raw: str) -> None:
    data = raw.encode("utf-8")
    digest.update(len(data).to_bytes(8, "big"))
    digest.update(data)


def envelope(source_id, source_time, raw, time_column):
    record = json.loads(raw)
    if type(record.get("id")) is not int or record["id"] != source_id:
        raise ArchiveError("source ID differs from complete row JSON")
    if source_time.tzinfo is None:
        raise ArchiveError("source timestamp has no timezone")
    if utc(record[time_column]) != source_time:
        raise ArchiveError("timestamp projection differs from complete row JSON")
    projected = {}
    for name, fallback in (
        ("model", "resolved_model"),
        ("provider_id", None),
        ("final_status", None),
        ("error_reason", "reason_code"),
    ):
        value = record.get(name, record.get(fallback) if fallback else None)
        if value is not None and not isinstance(value, str):
            raise ArchiveError(f"unexpected type for projected field {name}")
        projected[name] = value
    return {
        "source_id": source_id,
        "source_time": source_time.astimezone(UTC),
        **projected,
        "row_json": raw,
        "row_sha256": hashlib.sha256(raw.encode("utf-8")).hexdigest(),
    }


def encode(pages, path: Path, window: Window, expected: int) -> dict:
    digest = hashlib.sha256()
    count = raw_bytes = 0
    min_id = max_id = None
    first = last = previous = None
    with pq.ParquetWriter(path, ARCHIVE_SCHEMA, compression="zstd") as writer:
        for page in pages:
            encoded = []
            for source_id, source_time, raw in page:
                key = (source_time, source_id)
                if previous is not None and key <= previous:
                    raise ArchiveError("source rows are not strictly ordered")
                if not window.start <= source_time < window.end:
                    raise ArchiveError("source row lies outside the requested window")
                previous = key
                row = envelope(source_id, source_time, raw, TABLES[window.table])
                encoded.append(row)
                digest_row(digest, raw)
                count += 1
                raw_bytes += len(raw.encode("utf-8"))
                if count > window.max_rows or raw_bytes > window.max_raw_bytes:
                    raise ArchiveError("snapshot size limit reached; reduce the window")
                min_id = source_id if min_id is None else min(min_id, source_id)
                max_id = source_id if max_id is None else max(max_id, source_id)
                first = first or source_time
                last = source_time
            if encoded:
                writer.write_table(pa.Table.from_pylist(encoded, schema=ARCHIVE_SCHEMA))
    if count != expected:
        raise ArchiveError("snapshot count differs from the source COUNT in the same transaction")
    return {
        "rows": count,
        "raw_bytes": raw_bytes,
        "content_sha256": digest.hexdigest(),
        "min_id": min_id,
        "max_id": max_id,
        "first_time": stamp(first) if first else None,
        "last_time": stamp(last) if last else None,
        "file_sha256": file_sha256(path),
        "file_bytes": path.stat().st_size,
    }


def verify_parquet(path: Path, window: Window, expected: dict) -> None:
    if path.stat().st_size != expected["file_bytes"]:
        raise ArchiveError("Parquet file length mismatch")
    if file_sha256(path) != expected["file_sha256"]:
        raise ArchiveError("Parquet file checksum mismatch")
    parquet = pq.ParquetFile(path)
    if not parquet.schema_arrow.equals(ARCHIVE_SCHEMA, check_metadata=True):
        raise ArchiveError("Parquet schema mismatch")
    digest = hashlib.sha256()
    count = raw_bytes = 0
    min_id = max_id = None
    first = last = previous = None
    for batch in parquet.iter_batches(batch_size=1000):
        for row in batch.to_pylist():
            rebuilt = envelope(
                row["source_id"], row["source_time"], row["row_json"], TABLES[window.table]
            )
            if rebuilt != row:
                raise ArchiveError("decoded projection or row digest differs from complete JSON")
            key = (row["source_time"], row["source_id"])
            if previous is not None and key <= previous:
                raise ArchiveError("decoded rows are not strictly ordered")
            previous = key
            if not window.start <= row["source_time"] < window.end:
                raise ArchiveError("decoded row outside the archive interval")
            digest_row(digest, row["row_json"])
            count += 1
            raw_bytes += len(row["row_json"].encode("utf-8"))
            min_id = row["source_id"] if min_id is None else min(min_id, row["source_id"])
            max_id = row["source_id"] if max_id is None else max(max_id, row["source_id"])
            first = first or row["source_time"]
            last = row["source_time"]
    actual = {
        "rows": count,
        "raw_bytes": raw_bytes,
        "content_sha256": digest.hexdigest(),
        "min_id": min_id,
        "max_id": max_id,
        "first_time": stamp(first) if first else None,
        "last_time": stamp(last) if last else None,
    }
    if any(expected[key] != value for key, value in actual.items()):
        raise ArchiveError("decoded content does not match the source snapshot receipt")
