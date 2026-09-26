import hashlib
from dataclasses import replace
from datetime import timedelta

import pyarrow as pa
import pyarrow.parquet as pq
import pytest

from telemetry_archive.artifact import read_artifact, validate_receipt
from telemetry_archive.codec import encode, file_sha256, verify_parquet
from telemetry_archive.model import ARCHIVE_SCHEMA, ArchiveError, Window, utc


@pytest.mark.parametrize(
    "table", ["usage", "ledger_entries", "balances", "users", "request_profiles;DROP TABLE users"]
)
def test_financial_and_unknown_tables_rejected(window, table):
    with pytest.raises(ValueError):
        replace(window, table=table)


def test_window_limits(window):
    for change in (
        {"end": window.start},
        {"end": window.start + timedelta(hours=2)},
        {"start": window.start.replace(tzinfo=None)},
        {"page_rows": 10001},
        {"max_rows": 0},
        {"max_raw_bytes": 2 * 1024**3 + 1},
        {"max_seconds": 301},
    ):
        with pytest.raises(ValueError):
            replace(window, **change)
    with pytest.raises(ValueError, match="midnight"):
        Window(window.table, utc("2026-09-01T23:59:00Z"), utc("2026-09-02T00:01:00Z"))


def test_complete_json_and_sparse_ids_roundtrip(artifact, rows, window):
    directory, receipt = artifact
    verify_parquet(directory / "data.parquet", window, receipt["stats"])
    decoded = pq.read_table(directory / "data.parquet").to_pylist()
    assert [row["row_json"] for row in decoded] == [raw for _, _, raw in rows]
    assert receipt["stats"]["rows"] == 3
    assert receipt["retention_eligible"] is False


def test_empty_snapshot(tmp_path, window):
    path = tmp_path / "empty.parquet"
    stats = encode([], path, window, 0)
    verify_parquet(path, window, stats)
    assert stats["min_id"] is None


@pytest.mark.parametrize("kind", ["order", "window", "source_count", "size", "row_limit"])
def test_incomplete_or_invalid_input_rejected(tmp_path, window, rows, kind):
    expected = 3
    if kind == "order":
        rows = list(reversed(rows))
    elif kind == "window":
        rows[0] = (1, window.end, rows[0][2])
    elif kind == "source_count":
        expected = 4
    elif kind == "size":
        window = replace(window, max_raw_bytes=10)
    elif kind == "row_limit":
        window = replace(window, max_rows=2)
    with pytest.raises(ArchiveError):
        encode([rows], tmp_path / "bad.parquet", window, expected)


def test_corrupt_bytes_rejected(artifact):
    directory, _ = artifact
    with (directory / "data.parquet").open("ab") as stream:
        stream.write(b"corruption")
    with pytest.raises(ArchiveError, match="length"):
        read_artifact(directory)


@pytest.mark.parametrize("change", ["projection", "time_projection", "raw_json", "missing_row"])
def test_decoded_semantic_corruption_rejected(artifact, window, change):
    directory, receipt = artifact
    path = directory / "data.parquet"
    decoded = pq.read_table(path).to_pylist()
    if change == "projection":
        decoded[0]["model"] = "wrong/model"
    elif change == "time_projection":
        decoded[1]["source_time"] += timedelta(microseconds=1)
    elif change == "raw_json":
        decoded[0]["row_json"] += " "
        decoded[0]["row_sha256"] = hashlib.sha256(decoded[0]["row_json"].encode()).hexdigest()
    else:
        decoded.pop()
    pq.write_table(pa.Table.from_pylist(decoded, schema=ARCHIVE_SCHEMA), path, compression="zstd")
    expected = dict(receipt["stats"], file_sha256=file_sha256(path), file_bytes=path.stat().st_size)
    with pytest.raises(ArchiveError):
        verify_parquet(path, window, expected)


def test_receipt_tampering_rejected(artifact):
    _, receipt = artifact
    receipt["stats"]["rows"] += 1
    with pytest.raises(ArchiveError, match="receipt checksum"):
        validate_receipt(receipt)


def test_no_retention_receipt_accepted(artifact):
    _, receipt = artifact
    receipt["retention_eligible"] = True
    with pytest.raises(ArchiveError, match="copy-only"):
        validate_receipt(receipt)
